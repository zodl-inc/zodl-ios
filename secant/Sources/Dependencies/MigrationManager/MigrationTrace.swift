//
//  MigrationTrace.swift
//  zodl
//
//  MOB-1466 — THE MIGRATION TIMELINE.
//
//  A migration has two almost independent halves. (A) the business logic — proving, scheduling,
//  broadcasting — which the user never sees and which is, by this point, largely correct: the funds
//  do move. (B) the interface — what we say, what we show, and WHEN. Only (B) is what a user
//  experiences, and a banner that says one thing and replaces it two seconds later is, to them,
//  indistinguishable from a bug. It will be reported as one, and they will be right to report it.
//
//  Debugging (B) from a log of (A) is hopeless, because the two failure modes look identical in a
//  flat stream: a banner printed forty times because forty recomputes agreed is the same forty lines
//  as a banner that flickered forty times. This file exists to make them different.
//
//  Three properties, and every one of them is load-bearing:
//
//  1. SESSIONS. On iOS every migration step happens inside one app-open, and nothing at all happens
//     between them. A log without open/background boundaries cannot answer "what did THIS session
//     do", which is the only question that matters when the answer to "did the migration work" is
//     "yes, eventually". Each session gets an ordinal (`s1`, `s2`, …) and a cause — cold launch,
//     foreground, a tapped poke — so two sessions can be told apart and related.
//
//  2. ELAPSED TIME. Every line carries `+N.NNs` since that session opened, and sessions carry a wall
//     clock. "The banner flipped 2 s after open" is a measurement, not an impression.
//
//  3. TRANSITIONS, NOT STATES. The banner and the route are logged only when they CHANGE, with how
//     long the previous value was on screen. A state that held for four minutes prints once; a state
//     that held for 1.8 s prints once and is flagged. `⚠ FLICKER` is the automated version of the
//     complaint this file was written for.
//
//  Deliberately a plain enum over a lock rather than a dependency: every call site here is already
//  inside `MigrationManagerImpl` or Root's reducer, tracing must never fail or need injecting, and a
//  test that wants silence simply never opens a session. Timestamps are computed arithmetically in
//  UTC rather than through a `DateFormatter` — no locale, no thread-safety question, and it matches
//  the `+0000` the SDK's own lines already print.
//

import Foundation
import os
@preconcurrency import ZcashLightClientKit

enum MigrationTrace {
    /// Why this app-open happened. The distinction the field asked for first: an open that the app
    /// ASKED for (a poke fired, the user tapped it) is a different event from one the user chose,
    /// and a run's health reads completely differently depending on which kind it is getting.
    enum Cause: String {
        case coldLaunch = "cold launch"
        case foreground = "foreground"
        case backgroundTask = "background task"
        /// MOB-1466: a foreground migration TICK (Root's recurring 30s wake-up) reached a
        /// `.broadcast` action — see `MigrationStepDriver.execute`'s tick-phase case. Distinguishes
        /// a tick-triggered broadcast's own brief session from the ambient foreground session it
        /// interrupts; every OTHER tick (nothing due, or held) begins no session at all.
        case timer = "timer"
    }

    private struct Session {
        let ordinal: Int
        let startedAt: Date
        let cause: Cause

        var lastBanner: String?
        var lastBannerAt: Date
        var lastRoute: String?
        var lastRouteAt: Date
        var lastRows: String?

        // Session counters, replayed in the closing summary — the one line that says what this
        // app-open was FOR.
        var bannerTransitions = 0
        var flickers = 0
        var proveSweeps = 0
        var proved = 0
        var broadcasts = 0
        var syncsCompleted = 0
    }

    /// Anything a banner held for less than this and then replaced is reported as a flicker. Chosen
    /// as "shorter than a person can read a two-line banner and decide what it means" — the point is
    /// not the exact number, it is that a threshold exists and the log applies it every time instead
    /// of waiting for someone to notice.
    private static let flickerThreshold: TimeInterval = 3.0

    private static let state = OSAllocatedUnfairLock<Session?>(initialState: nil)
    private static let sessionCounter = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// The live session's ordinal, or `nil` when no session is open.
    ///
    /// ONE DERIVATION, TWO RENDERINGS. The banner and the migration screen each used to derive
    /// migration state independently, at different moments, and every banner-vs-screen contradiction
    /// reported this week was that gap showing. This is the shared key that closes it: a surface
    /// rendering data stamped with an older ordinal KNOWS it is stale, without having to guess from
    /// timers or compare its own heights.
    ///
    /// Deliberately the session ordinal rather than a timestamp — "which app-open produced this" is
    /// exactly the question, and it needs no tolerance to answer.
    static var currentSessionOrdinal: Int? {
        state.withLock { $0?.ordinal }
    }

    /// The armed poke, remembered across sessions so an open can be related to it: opening well
    /// before it is a manual visit, opening at it is the schedule working, opening long after it is
    /// a poke that was missed or ignored. Survives backgrounding, which is exactly when it matters.
    private static let armedPoke = OSAllocatedUnfairLock<Date?>(initialState: nil)

    // MARK: - Session boundaries

    static func beginSession(cause: Cause, tip: BlockHeight) {
        let now = Date()

        // Audit 2026-08-03 (#18): a `.timer` cause is a tick-triggered broadcast INSIDE a live
        // foreground session, not a new app-open — replacing the session here discarded the
        // foreground's dwell/flicker/counters mid-flight, disabled flicker detection for the rest
        // of the open, and nothing ever ended the replacement (endSession's only caller is the
        // background boundary). A live session instead gets a marker line and keeps its
        // continuity; a `.timer` begin with NO live session (defensive — the tick loop is
        // foreground-only) still opens one below, exactly as before.
        if cause == Cause.timer {
            let marked = state.withLock { session -> Int? in
                session?.ordinal
            }
            if let marked {
                LoggerProxy.event(
                    "[MIG s\(marked)] ▸ tick broadcast session at \(clock(now)) — tip \(tip)\(pokeRelation(now: now))"
                )
                return
            }
        }

        let ordinal = sessionCounter.withLock { counter -> Int in
            counter += 1
            return counter
        }

        state.withLock { session in
            session = Session(
                ordinal: ordinal,
                startedAt: now,
                cause: cause,
                lastBanner: nil,
                lastBannerAt: now,
                lastRoute: nil,
                lastRouteAt: now,
                lastRows: nil
            )
        }

        LoggerProxy.event(
            "[MIG s\(ordinal) +0.00s] ══ APP OPEN (\(cause.rawValue)) at \(clock(now)) — tip \(tip)\(pokeRelation(now: now))"
        )
    }

    static func endSession(reason: String) {
        let now = Date()
        let closing = state.withLock { session -> Session? in
            let closing = session
            session = nil
            return closing
        }

        guard let closing else { return }

        let lasted = now.timeIntervalSince(closing.startedAt)
        LoggerProxy.event(
            "[MIG s\(closing.ordinal) +\(seconds(lasted))s] ══ \(reason) at \(clock(now)) — session lasted \(seconds(lasted))s"
            + " · banner changes \(closing.bannerTransitions)"
            + (closing.flickers > 0 ? " (⚠ \(closing.flickers) flicker\(closing.flickers == 1 ? "" : "s"))" : "")
            + " · prove sweeps \(closing.proveSweeps) (proved \(closing.proved))"
            + " · broadcasts \(closing.broadcasts)"
            + " · syncs completed \(closing.syncsCompleted)"
            + " · last banner \(closing.lastBanner ?? "none")"
        )
    }

    // MARK: - The stamped prefix every other `[MIG]` line already uses

    /// `MigrationManagerImpl.logTag`'s value — so every pre-existing `[MIG] …` line gains its
    /// session and elapsed stamp without a single call site changing.
    static func tag() -> String {
        guard let session = state.withLock({ $0 }) else { return "[MIG s- +0.00s]" }
        return "[MIG s\(session.ordinal) +\(seconds(Date().timeIntervalSince(session.startedAt)))s]"
    }

    // MARK: - Events

    static func event(_ message: String) {
        LoggerProxy.event("\(tag()) \(message)")
    }

    /// A poke fired and the user tapped it — the answer to "was this open the schedule working, or
    /// the user wandering in". Logged with its own elapsed, so a tap 0.3 s into a session reads
    /// unmistakably as the cause of that session.
    static func notificationTapped() {
        event("🔔 NOTIFICATION TAPPED — this open was poked")
    }

    static func notificationArmed(at date: Date, source: String) {
        armedPoke.withLock { $0 = date }
        event("🔔 poke armed for \(clock(date)) (in \(seconds(date.timeIntervalSinceNow))s) — \(source)")
    }

    static func notificationCancelled(_ why: String) {
        armedPoke.withLock { $0 = nil }
        event("🔔 poke cancelled — \(why)")
    }

    // MARK: - Transitions (the reason this file exists)

    /// Logs the banner ONLY when it changes, with the dwell time of the value it replaces, and flags
    /// anything that held for less than `flickerThreshold`.
    ///
    /// `why` is the deciding input, not a restatement of the variant — "submitting", "prove sweep
    /// finished", "transfer 2 mined". A transition without a reason is a fact; a transition with one
    /// is a diagnosis.
    static func banner(_ variant: MigrationBannerVariant?, why: String, detail: String) {
        let now = Date()
        let rendered = variant.map { String(describing: $0) } ?? "none"

        let line: String? = state.withLock { session -> String? in
            guard var current = session else { return nil }
            defer { session = current }

            guard current.lastBanner != rendered else { return nil }

            let previous = current.lastBanner
            let dwell = now.timeIntervalSince(current.lastBannerAt)
            let isFlicker = previous != nil && dwell < flickerThreshold

            current.lastBanner = rendered
            current.lastBannerAt = now
            current.bannerTransitions += 1
            if isFlicker { current.flickers += 1 }

            let stamp = "[MIG s\(current.ordinal) +\(seconds(now.timeIntervalSince(current.startedAt)))s]"
            let from = previous.map { "\($0) [held \(seconds(dwell))s]" } ?? "(first)"
            let flicker = isFlicker ? "  ⚠ FLICKER — \(previous ?? "?") was on screen for only \(seconds(dwell))s" : ""

            return "\(stamp) BANNER: \(from) → \(rendered)  ·  why: \(why)  ·  \(detail)\(flicker)"
        }

        if let line {
            LoggerProxy.event(line)
        }
    }

    /// Same treatment for the banner's TAP TARGET. A route that changes without the banner changing
    /// means the same words now open a different screen, which the user experiences as the app
    /// having lied to them.
    static func route(_ route: MigrationReentryRoute, detail: String) {
        let now = Date()
        let rendered = String(describing: route)

        let line: String? = state.withLock { session -> String? in
            guard var current = session else { return nil }
            defer { session = current }
            guard current.lastRoute != rendered else { return nil }

            let previous = current.lastRoute
            let dwell = now.timeIntervalSince(current.lastRouteAt)
            current.lastRoute = rendered
            current.lastRouteAt = now

            let stamp = "[MIG s\(current.ordinal) +\(seconds(now.timeIntervalSince(current.startedAt)))s]"
            let from = previous.map { "\($0) [held \(seconds(dwell))s]" } ?? "(first)"
            return "\(stamp) ROUTE: \(from) → \(rendered)  ·  \(detail)"
        }

        if let line {
            LoggerProxy.event(line)
        }
    }

    /// A one-line render of what the TIMELINE shows, deduplicated on its own signature — the other
    /// half of every "banner says X, list says Y" report, in the same stream and on the same clock.
    static func rows(transfers: [MigrationTransferRow], preparations: [MigrationTransferRow]) {
        let rendered = (preparations.map { render($0, prefix: "P") } + transfers.map { render($0, prefix: "T") })
            .joined(separator: " ")
        guard !rendered.isEmpty else { return }

        let line: String? = state.withLock { session -> String? in
            guard var current = session else { return nil }
            defer { session = current }
            guard current.lastRows != rendered else { return nil }
            current.lastRows = rendered

            let stamp = "[MIG s\(current.ordinal) +\(seconds(Date().timeIntervalSince(current.startedAt)))s]"
            return "\(stamp) ROWS: \(rendered)"
        }

        if let line {
            LoggerProxy.event(line)
        }
    }

    // MARK: - Slow reads

    /// Times a migration read and logs it ONLY when it crosses `slowReadThreshold`.
    ///
    /// Field-caught 2026-08-01: tapping the banner gave a blank screen with a spinner for ~10 s.
    /// Every screen in this flow is assembled from several SDK round trips (state, progress,
    /// statuses, overdue, clock, schedule), each of which crosses the FFI and touches the wallet
    /// database — and the prove sweep runs on that same database. Which of them is slow, and whether
    /// it is slow always or only under contention, is not answerable by staring at a spinner.
    ///
    /// Silent below the threshold on purpose: a line per read would drown the timeline this file
    /// exists to keep readable, and a read that returns promptly is not information.
    static func timed<T>(_ label: String, _ work: () async -> T) async -> T {
        let started = Date()
        let result = await work()
        let elapsed = Date().timeIntervalSince(started)
        if elapsed >= slowReadThreshold {
            event("🐌 SLOW READ \(label) took \(seconds(elapsed))s")
        }
        return result
    }

    /// Half the shortest interval a person notices as a "wait". Anything under this is invisible;
    /// anything over it is a spinner the user is watching.
    private static let slowReadThreshold: TimeInterval = 1.0

    // MARK: - Counters

    static func recordProveSweep(proved: Int) {
        state.withLock { session in
            session?.proveSweeps += 1
            session?.proved += proved
        }
    }

    static func recordBroadcast() {
        state.withLock { $0?.broadcasts += 1 }
    }

    static func recordSyncCompleted() {
        state.withLock { $0?.syncsCompleted += 1 }
    }

    // MARK: - Rendering

    private static func render(_ row: MigrationTransferRow, prefix: String) -> String {
        let number = "\(prefix)\(row.index + 1)"
        if row.isBroadcasting { return "\(number):broadcast" }
        if row.isPreparing { return "\(number):preparing" }
        switch row.status {
        case .sent: return "\(number):done"
        // R11: on the chain's side, wallet not yet counted it. (A still-broadcast row prints
        // ":broadcast" via the flag check above, so the trace tells the two phases apart for free.)
        case .confirming: return "\(number):confirming"
        case .invalid: return "\(number):invalid"
        case .expired: return "\(number):expired"
        case .overdue: return "\(number):overdue"
        case .active, .pending:
            // MOB-1466: the trace distinguishes "ready" from "no tip to answer with" too — a log
            // reading `ready` for eleven rows because the clock was blank is how this bug hid.
            guard let minutes = row.forwardETAMinutes else { return "\(number):eta?" }
            return minutes <= 0 ? "\(number):ready" : "\(number):~\(minutes)m"
        }
    }

    /// How this open relates to the poke we last armed — manual, on schedule, or late. The single
    /// most useful piece of context at the top of a session, and the reason `armedPoke` outlives the
    /// session that set it.
    private static func pokeRelation(now: Date) -> String {
        guard let armed = armedPoke.withLock({ $0 }) else { return " · no poke armed" }
        let delta = armed.timeIntervalSince(now)
        if delta > 30 {
            return " · MANUAL open — armed poke is \(seconds(delta))s away (\(clock(armed)))"
        }
        if delta < -30 {
            return " · LATE open — armed poke was \(seconds(-delta))s ago (\(clock(armed)))"
        }
        return " · ON SCHEDULE — armed poke at \(clock(armed))"
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.2f", interval)
    }

    /// `HH:mm:ss.SSS` in UTC, computed arithmetically — no `DateFormatter`, so no locale surprises
    /// and no thread-safety question inside the lock. UTC to match the `+0000` the SDK's own lines
    /// already print, so the two streams interleave on one clock.
    private static func clock(_ date: Date) -> String {
        let total = date.timeIntervalSince1970
        let wholeSeconds = Int(total.rounded(.down))
        let millis = Int(((total - Double(wholeSeconds)) * 1000).rounded())
        let secondsOfDay = wholeSeconds % 86_400
        return String(
            format: "%02d:%02d:%02d.%03dZ",
            secondsOfDay / 3600,
            (secondsOfDay % 3600) / 60,
            secondsOfDay % 60,
            millis
        )
    }
}
