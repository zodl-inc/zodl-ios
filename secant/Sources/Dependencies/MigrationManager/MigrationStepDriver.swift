//
//  MigrationStepDriver.swift
//  zodl
//
//  THE DRIVER: the one place the app obeys the migration engine.
//
//  `MigrationStepPlan` is the decision table (step × phase -> action) and it is pure. This file is
//  its executor, and between them they are the whole of the app's migration control flow. Nothing
//  else in the app may read `migrationAdvanceStep` and act on it; nothing else may decide what a
//  migration app-open does.
//
//  WHAT THIS REPLACED. The app used to read the engine's step in one place (`visitKind`), branch on
//  `.broadcast` alone, and discard the other five answers — then run its own sweeps and lanes on a
//  schedule of its own devising. `.rebuild` and `.requiresAttention` had no automatic discharge at
//  all: their only callers sat behind buttons on screens the user had to find, so a run whose next
//  step was either of those stopped dead and stayed dead across any number of app-opens. Meanwhile
//  the banner and the re-entry route derived from app-side block-height math rather than from the
//  step, so what the app OFFERED ("Send now", "Reschedule") and what the engine would ACCEPT had
//  drifted apart. That pair — a step nobody discharges plus a CTA the engine refuses — is the
//  send-now/reschedule loop with nothing behind it.
//
//  THE INVARIANTS this file exists to hold. All five are load-bearing; each one is a bug we shipped.
//
//   I1  EVERY STEP HAS A DISCHARGE. `MigrationStepPlan.action(for:phase:)` is exhaustive with no
//       `default:`. A new engine step is a compile error, not a new deadlock.
//   I2  EVERY OPEN ENDS WITH A VERDICT. `advance` always logs what it did and why, including
//       "nothing, because X". A session that did nothing and said nothing is indistinguishable from
//       a frozen app — that is precisely how six minutes of stale spinners got diagnosed as
//       "probably finished".
//   I3  PROGRESS OR ESCALATION, NEVER SILENCE. When the app cannot discharge a step itself it
//       records a `MigrationStepBlocker` so the banner and route can offer the ONE action that
//       moves the run. It never sits on a step it cannot take.
//   I4  ENTRY-INDEPENDENT. Tapping the icon and tapping a notification run the identical driver
//       calls in the identical order. A notification tap adds navigation and nothing else.
//   I5  NO SELF-DISARM. A session that suppresses sync always arms its own resume. (N4: a broadcast
//       session used to suppress sync, fail to arm the resume, and freeze the run for the whole
//       app-open.)
//
//  See `docs/slipstream/migration/MIGRATION_STACK_MAP.md` for the engine-to-app picture.
//

import Foundation
@preconcurrency import ZcashLightClientKit
import os

/// What one `advance` call actually did — the session verdict of I2, and the driver's return value.
///
/// Every case is a sentence the log can print and a human can act on. `.held` is deliberately
/// distinct from `.idle`: "the privacy buffer is holding this for four more minutes" and "there is
/// genuinely nothing to do" look the same on screen and could not be told apart in a log.
enum MigrationStepVerdict: Equatable, Sendable {
    /// Migration is not applicable — flag off, Ironwood not activated, or no candidate accounts.
    case notApplicable
    /// No run is stored for any candidate account.
    case noRun
    /// A transfer was broadcast. ZIP 318: this session carried exactly one, and it is over.
    case broadcast(id: UInt32)
    /// A broadcast was due but withheld, with the reason. Holding is a legitimate outcome; being
    /// unable to say why is not.
    case held(reason: String)
    /// The prove sweep produced this many proofs (`0` is the ordinary "nothing was ready" answer).
    case proved(count: Int)
    /// An expired transfer was rebuilt in place, without the user.
    case rebuilt(id: UInt32)
    /// A broadcast this app made was rejected by a node whose chain view is ahead of this wallet's.
    /// This session syncs and the engine adjudicates on the next ask. Carries no id: upstream's
    /// `Reevaluate` names no transaction, and neither may we.
    case reevaluating
    /// The app cannot take this step alone. The blocker names what the user must do.
    case needsUser(MigrationStepBlocker)
    /// Nothing is actionable; wake-ups are armed.
    case idle
    /// The stored run is terminal.
    case complete
    /// The step's discharge belongs to the other phase of this same open. Not an error, not a stall
    /// — the session proceeds and the driver is asked again at the edge.
    case deferredToPhase
    /// A discharge was attempted and failed. Carries the reason; never swallowed.
    case failed(String)
    /// The call yielded without reading the engine at all. Two producers:
    /// - MOB-1466: a `.tick` arrived while another `advance` call was already in flight — the
    ///   single-flight latch's fast-reject path. Quiet by construction (see `isQuietForTick`): a
    ///   busy driver is not news the way a stalled or blocked run is, and logging it at `.event`
    ///   every time a 30s tick loses this race would be exactly the noise the tick's own log
    ///   hygiene exists to avoid. Ticks never park (FIFO waiting is the open lanes' privilege).
    /// - R0: an open lane (`.beforeSync`/`.afterSync`) whose per-session credit is already spent,
    ///   or that was called with no live session at all (fail-closed) — see the R0 credit gate in
    ///   `advance(phase:)`. Always `.event`-logged: a refused open-lane drive is the law working,
    ///   and the log line is how a field trace proves which path over-asked.
    case skipped
}

extension MigrationStepVerdict {
    /// Whether THIS verdict, produced at `.tick`, is quiet enough that the tick loop's wake-up
    /// should be treated as a no-op: no re-arm (arming reflects the run's ROWS, and a quiet tick
    /// changed none of them) and a `.debug`, not `.event`, log line (an idle tick every 30s must
    /// not compete, in volume, with the app-open lines every other `[MIG]` reader filters for).
    /// See `MigrationManagerImpl.advance(phase:)`'s tick-specific arming/log hygiene.
    ///
    /// EXHAUSTIVE BY CONSTRUCTION, the same discipline `MigrationStepPlan.action(for:phase:)` holds
    /// (I1): a verdict added to this enum must be classified here before the project compiles, so a
    /// new SUBSTANTIVE verdict can never silently fall quiet, and a new quiet one can never silently
    /// start spamming `.event` every 30 seconds.
    var isQuietForTick: Bool {
        switch self {
        case MigrationStepVerdict.notApplicable,
             MigrationStepVerdict.noRun,
             MigrationStepVerdict.held,
             MigrationStepVerdict.idle,
             MigrationStepVerdict.complete,
             MigrationStepVerdict.deferredToPhase,
             MigrationStepVerdict.skipped:
            return true
        case MigrationStepVerdict.broadcast,
             MigrationStepVerdict.proved,
             MigrationStepVerdict.rebuilt,
             MigrationStepVerdict.reevaluating,
             MigrationStepVerdict.needsUser,
             MigrationStepVerdict.failed:
            return false
        }
    }
}

extension MigrationManagerImpl {
    /// THE DRIVER. Ask the engine for the next step, discharge exactly that step, end the session.
    ///
    /// Called at exactly two moments per app-open — `.beforeSync` (before the wire is touched) and
    /// `.afterSync` (the sync-complete edge) — from Root, and from nowhere else. Both entry paths,
    /// icon tap and notification tap, reach the same two calls in the same order (I4).
    ///
    /// Per-account, in the engine's own priority order, but ZIP 318's session decision is
    /// wallet-wide and taken FIRST, from the same batch of steps this call is about to discharge —
    /// not from a second, independent read that could disagree with it. That single-read property
    /// is what makes the "two clocks" class of bug impossible here.
    ///
    /// Never throws. A migration read failure must not be able to brick ordinary wallet syncing, so
    /// every internal failure degrades to a logged `.failed` verdict and the wallet carries on.
    ///
    /// MOB-1466: SINGLE-FLIGHT, around the whole body below. `.tick` — Root's recurring 30s
    /// foreground wake-up — tries the latch ONCE and yields (`.skipped`, no engine read at all) if
    /// another `advance` is already running; `.beforeSync`/`.afterSync` — an app-open's own driver
    /// calls — wait their turn (FIFO) instead, because an open's call must never be silently
    /// dropped for arriving mid-tick. See `advanceLatch`'s doc and the acquire/release functions
    /// below for the mechanism.
    @discardableResult
    func advance(phase: MigrationOpenPhase) async -> MigrationStepVerdict {
        if phase == .tick {
            LoggerProxy.debug("\(Self.logTag) ▸ Tick (\(phase))")
        }

        guard isIronwoodActivated() else {
            return MigrationStepVerdict.notApplicable
        }

        // R0 — THE GROUND RULE OF ALL GROUND RULES (Lukas, 2026-08-05): one zodl open = ONE
        // `nextStep()` pass, and nothing may ever drive an open lane again in the same foreground
        // session — not a second launch path (C6-1: an open traversing two of Root's `.beforeSync`
        // sites broadcast twice, 4 s apart — a ZIP 318 violation, the engine schedules those sends
        // APART), not a re-firing sync edge (`.afterSync` has two call sites of its own), not
        // navigation, not "something finished so ask again". Enforced here, at the chokepoint every
        // path shares, as consumable per-session credits: `beginSession` (cold launch / foreground)
        // arms ONE credit per open lane by rolling the ordinal; the lane's first drive consumes it;
        // every later same-session call yields with a logged verdict.
        //
        // FAIL-CLOSED: no live session = no credit = no drive. An open lane acting outside a
        // session would be exactly the "code calls nextStep() on its own clock" R0 exists to ban —
        // production always has one (`beginSession` is the first statement of both entry reducers),
        // so the refusal can only fire where it should: a background wake-up, a stray completion
        // handler, a future call site added outside the open. `.tick` is not an open lane and is
        // governed separately (mode belt, privacy buffer, engine schedule — see
        // `MigrationStepPlan`'s "THE THIRD PHASE").
        if phase == MigrationOpenPhase.beforeSync || phase == MigrationOpenPhase.afterSync {
            guard let sessionOrdinal = sessionOrdinalProvider() else {
                LoggerProxy.event(
                    "\(Self.logTag) ▸ session verdict (\(phase)): skipped — no live session; open-lane drives are fail-closed (R0)"
                )
                MigrationTrace.event("\(phase) REFUSED — no live session (R0 fail-closed)")
                return MigrationStepVerdict.skipped
            }
            let alreadyDriven = openLaneCredits.withLock { credits -> Bool in
                if phase == MigrationOpenPhase.beforeSync {
                    if credits.beforeSyncSpentSession == sessionOrdinal { return true }
                    credits.beforeSyncSpentSession = sessionOrdinal
                    return false
                } else {
                    if credits.afterSyncSpentSession == sessionOrdinal { return true }
                    credits.afterSyncSpentSession = sessionOrdinal
                    return false
                }
            }
            if alreadyDriven {
                LoggerProxy.event(
                    "\(Self.logTag) ▸ session verdict (\(phase)): skipped — \(phase) already driven this session (R0 once-credit)"
                )
                MigrationTrace.event("\(phase) SKIPPED — already driven this session (R0 once-credit)")
                return MigrationStepVerdict.skipped
            }
        }

        if phase == MigrationOpenPhase.tick {
            guard tryAcquireAdvanceLatch() else {
                LoggerProxy.debug("\(Self.logTag) ▸ session verdict (\(phase)): skipped — another advance is already in flight")
                return MigrationStepVerdict.skipped
            }
        } else {
            await acquireAdvanceLatch()
        }
        defer { releaseAdvanceLatch() }

        let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: selectedWalletAccount?.id,
            walletAccounts: walletAccounts
        )
        guard !accountUUIDs.isEmpty else {
            return MigrationStepVerdict.notApplicable
        }

        // FAST LANE compression is GONE (2026-08-05, with SDK PR #1951): the QA reschedule
        // endpoint is retired upstream — scheduling belongs to the engine, and test-network
        // schedules arrive compressed at commit time (the interim spacing-floor knob on the
        // advance call left the SDK with the librustzcash rebase). The old app-side rewrite also
        // re-ran per session (its once-latch was per driver instance), desyncing scheds from
        // anchors — campaign 9's F-C9-3. `MigrationFastLane` is gone entirely with the privacy
        // buffer it existed to zero.

        // MOB-1466's TICK FAST PATH was deleted 2026-08-07. It was a cheap wallet-wide reject that
        // answered "the post-sync privacy buffer is still holding" without paying for a per-account
        // engine read — and with that buffer gone there is no wallet-wide timed answer to give.
        // A tick now goes straight to the engine reads below, which is the only thing that can
        // actually say whether a step is due.

        // ONE read of the engine, for every candidate account, feeding BOTH the wallet-wide session
        // decision and the per-account discharge below. The old code read `migrationAdvanceStep`
        // once in `visitKind` for the session decision and again inside `runBroadcastSession` for
        // the delivery, and a tip that moved between the two reads made them disagree.
        //
        // NOT `try?` (audit 2026-08-03, P1): flattening a THROWN read into `nil` made a transient
        // engine error indistinguishable from "no run stored" — and `.noRun` is the verdict the
        // tick loop SELF-CANCELS on, so one contended read (a prove sweep holding the wallet DB,
        // a synchronizer mid-teardown) killed the tick lane for the rest of the session. This is
        // the exact flattening `MigrationManagerLiveKey`'s own state-read doc forbids. A throw is
        // recorded per-account; accounts that read cleanly still discharge, and an all-throw pass
        // surfaces as `.failed` below — substantive, event-logged, loop-surviving.
        var steps: [(accountUUID: AccountUUID, advance: MigrationAdvance?)] = []
        // MOB-1466: buffered, not logged immediately — a `.tick`'s log LEVEL depends on the verdict
        // these reads feed into, which isn't known until `discharge` below returns. See the emission
        // loop after it.
        var stepLogLines: [String] = []
        var stepReadFailure: String?
        for accountUUID in accountUUIDs {
            let advance: MigrationAdvance?
            do {
                advance = try await sdkSynchronizer.migrationAdvanceStep(accountUUID)
            } catch {
                stepReadFailure = "\(error.toZcashError())"
                stepLogLines.append("\(Self.logTag) advance step (\(phase)): READ FAILED — \(error.toZcashError())")
                continue
            }
            // THE key driver line, logged verbatim at both phases. A run sitting at 0-of-12 looks
            // identical whether the engine is saying `prove`, `waiting` or `broadcast` — this is the
            // line that tells those apart, and until 07-31 it was the one thing never written down.
            // The step keeps its verbatim print (grep-stable); the engine's outlook (#2936) rides as
            // a suffix when present — advisory, consumed by the arming pass below.
            let stepDescription = advance.map { String(describing: $0.step) } ?? "none (no run)"
            let outlookSuffix = advance?.next.map { " — next: \($0.kind) @ \($0.height)" } ?? ""
            stepLogLines.append("\(Self.logTag) advance step (\(phase)): \(stepDescription)\(outlookSuffix)")
            steps.append((accountUUID, advance))
        }

        var verdict = await discharge(steps: steps, phase: phase)
        if steps.isEmpty, let stepReadFailure {
            // EVERY candidate's read threw: the honest session answer is the failure, never
            // `.noRun` — "the engine could not be asked" and "there is nothing to do" must not
            // share a verdict (the latter self-cancels the tick loop).
            verdict = MigrationStepVerdict.failed("engine step read failed: \(stepReadFailure)")
        }

        // REEVALUATE IS "SYNC, THEN DO NOTHING" — nuttycom, 2026-08-08, reviewing the split at SDK
        // 93a11081: "this does reintroduce the sync-then-possibly-send identifiable behavior that
        // we don't want. I would prefer that 'reevaluate' operate as 'sync, then do nothing.'"
        //
        // The whole content of a `.reevaluate` is "this wallet's chain view is behind the node that
        // rejected a broadcast; let this session sync". It is only ever discharged at
        // `.beforeSync`. Left alone, the sync-completion edge then drives `.afterSync` on the SAME
        // open — and the engine, now holding the data it was waiting for, may well answer
        // `.broadcast`. That is a sync followed within seconds by a submission over one wire: the
        // same correlation SIGNATURE the deleted post-broadcast buffer was removed for, pointing
        // the other way. Nothing about it is fixed by spacing, so nothing here is timed.
        //
        // The session therefore SPENDS its `.afterSync` credit, unused. The edge still fires and
        // still syncs; R0's own gate answers `.skipped` when it asks to drive, and whatever the
        // engine now wants is served by the next open — a session that has no sync attached to it.
        // Burning the credit rather than adding a second suppression flag keeps one mechanism in
        // charge of "may this lane drive?", which is the property R0 exists to hold.
        if phase == MigrationOpenPhase.beforeSync,
           verdict == MigrationStepVerdict.reevaluating,
           let sessionOrdinal = sessionOrdinalProvider() {
            openLaneCredits.withLock { $0.afterSyncSpentSession = sessionOrdinal }
            LoggerProxy.event(
                "\(Self.logTag) reevaluate: this session syncs and STOPS — the post-sync edge is spent, so nothing broadcasts behind the sync"
            )
            MigrationTrace.event("reevaluate — sync, then nothing (afterSync lane spent)")
        }

        // MOB-1466: LOG HYGIENE. A quiet `.tick` verdict — nothing changed, nothing needed the user
        // — logs at `.debug`: every 30s, forever, while the app sits open with a scheduled run, is
        // not a volume `.event` (read by default) should carry. A SUBSTANTIVE tick verdict (a
        // broadcast, a rebuild, an escalation…) keeps `.event`, identically to `.beforeSync`/
        // `.afterSync`, which always do (`isQuietForTick` is never consulted for them below).
        let isQuietTick = phase == MigrationOpenPhase.tick && verdict.isQuietForTick
        for line in stepLogLines {
            isQuietTick ? LoggerProxy.debug(line) : LoggerProxy.event(line)
        }
        // I2: every open ends with a verdict, printed. Including — especially including — the
        // sessions that did nothing.
        let verdictLine = "\(Self.logTag) ▸ session verdict (\(phase)): \(verdict)"
        isQuietTick ? LoggerProxy.debug(verdictLine) : LoggerProxy.event(verdictLine)

        // GROUND_RULES R3: the session's verdict now EXISTS — this is the one edge that releases
        // the banner's `.checkingStatus` hold. Marked before the arming/poke below so the very
        // emissions that arming triggers already pass the banner's verdict gate.
        markSessionVerdictKnown()

        // MOB-1466: ARMING HYGIENE. Wake-ups are re-armed on every `.beforeSync`/`.afterSync` path,
        // not only the `.waiting` one — unchanged, see the doc this replaces. A QUIET `.tick`,
        // though, changed none of the run's rows (nothing to re-derive a schedule from), so arming
        // again would be pure repeated work for an identical answer; a SUBSTANTIVE tick verdict
        // keeps arming, exactly like the two opens.
        if !isQuietTick {
            for accountUUID in accountUUIDs {
                // P4: the account's own outlook from THIS drive's read — the single engine read
                // feeding the session decision, the discharge, the log, and now the arm.
                let outlook = steps.first { $0.accountUUID == accountUUID }?.advance?.next
                await armNextWindowNotifications(accountUUID: accountUUID, outlook: outlook)
            }
        }

        return verdict
    }

    /// Non-blocking acquire for `.tick` callers — see `advance(phase:)`'s single-flight latch.
    /// `true` means the latch is now held by THIS call; `false` means another `advance` is already
    /// running and this caller must yield (`.skipped`) rather than park.
    private func tryAcquireAdvanceLatch() -> Bool {
        advanceLatch.withLock { state in
            guard !state.isBusy else { return false }
            state.isBusy = true
            return true
        }
    }

    /// FIFO blocking acquire for `.beforeSync`/`.afterSync` callers — mirrors
    /// ../zcash-swift-wallet-sdk's `OrchardMigration.serializedBroadcastFlow`'s wait loop, adapted
    /// from actor isolation to an explicit lock (see `MigrationAdvanceLatchState`'s doc).
    ///
    /// The busy check and the enqueue-or-resume decision happen in ONE `withLock` call rather than
    /// two (check busy; if so, separately append a continuation) — splitting them would open a
    /// window in which a concurrent `releaseAdvanceLatch()` observes an EMPTY waiter list between
    /// the two calls and clears `isBusy`, stranding this continuation in the queue with nobody left
    /// to resume it. Calling `continuation.resume()` from inside the lock is safe: `resume()` is
    /// synchronous — it hands the continuation off, it does not itself suspend — so this never
    /// violates "no `await` inside `withLock`" (`OSAllocatedUnfairLock.withLock`'s closure is
    /// synchronous and could not compile an `await` inside it regardless).
    private func acquireAdvanceLatch() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            advanceLatch.withLock { state in
                if state.isBusy {
                    state.waiters.append(continuation)
                } else {
                    state.isBusy = true
                    continuation.resume()
                }
            }
        }
    }

    /// Releases the latch. When a caller is parked, ownership transfers DIRECTLY to the oldest one
    /// (FIFO) rather than clearing `isBusy` and letting whoever gets there first win — that is what
    /// keeps a `.tick` racing in from jumping the queue ahead of an app-open's own waiting call.
    private func releaseAdvanceLatch() {
        advanceLatch.withLock { state in
            guard !state.waiters.isEmpty else {
                state.isBusy = false
                return
            }
            let next = state.waiters.removeFirst()
            next.resume() // `isBusy` stays true — ownership transfers to the resumed waiter.
        }
    }

    /// The per-account discharge loop. Returns the FIRST substantive verdict — the engine's steps are
    /// already priority-ordered, and ZIP 318 caps a session at one broadcast, so "first substantive"
    /// is the honest summary of what this open accomplished.
    private func discharge(
        steps: [(accountUUID: AccountUUID, advance: MigrationAdvance?)],
        phase: MigrationOpenPhase
    ) async -> MigrationStepVerdict {
        var fallback = MigrationStepVerdict.noRun
        var firstHeld: MigrationStepVerdict?

        for (accountUUID, advance) in steps {
            let step = advance?.step
            // AUD-3: kind-awareness for the broadcast cells. A note-PREPARATION is ZIP-exempt from
            // the transfer-only throttles (session separation, buffer, mode belt, manual hold),
            // and the plan's `.afterSync` broadcast cell forks on it — so the kind is derived
            // BEFORE the plan is consulted, from the same statuses read every surface uses. Lazy:
            // only a `.broadcast` step pays the read.
            var isPreparationBroadcast = false
            if case let MigrationAdvanceStep.broadcast(instruction)? = step {
                isPreparationBroadcast = await preparationTransactionIds(accountUUID: accountUUID).contains(instruction.id)
            }
            var action = MigrationStepPlan.action(
                for: step,
                phase: phase,
                isPreparationBroadcast: isPreparationBroadcast
            )
            // The AUD-1 one-clock tiebreaker stood here: when the scanned-frame step said
            // `.waiting` but the estimate said a transfer was due, it synthesised a broadcast
            // action out of `hasOverdueMigrationTransfers(_, true)` plus a queue peek. DELETED
            // 2026-08-07 — and the FIND-5 wedge it patched is closed at the root, not merely
            // papered over. `migrationAdvanceStep` now applies the wall-clock estimate ITSELF, so
            // a `.waiting` answer is `.waiting` on the same clock every other surface uses: there
            // is no second clock left to reconcile, and no punctual window in which the two
            // disagree. The driver also receives estimate-judged steps it can dispatch directly,
            // so there is nothing left to synthesise. (It could not have survived regardless: the
            // queue peek it leaned on, `pendingMigrationTransferProposal`, is gone from the SDK.)

            let verdict = await execute(
                action,
                accountUUID: accountUUID,
                phase: phase,
                isPreparationBroadcast: isPreparationBroadcast
            )

            // Audit 2026-08-03 (#13): remember per-account whether this discharge needs the USER —
            // `armNextWindowNotifications` turns that into a near-term poke, because a blocked run
            // has no prove/send window of its own to wake anyone for.
            if case .needsUser = verdict {
                recordStepBlocker(accountUUID: accountUUID, isBlocked: true)
            } else {
                recordStepBlocker(accountUUID: accountUUID, isBlocked: false)
            }

            // `.held` is a PER-ACCOUNT outcome (audit 2026-08-03, #4): the mode belt and the
            // manual-delivery read hold ONE account's step, not the wallet's. Returning on the
            // first hold starved every later account — an `.immediate` account's permanently-due
            // broadcast blocked a `.privateScheduled` sibling's delivery on every single tick.
            // Remember the first hold as the session's summary and keep discharging; a later
            // account's SUBSTANTIVE verdict still wins the return below. (The wallet-wide
            // privacy buffer holds every account identically, so continuing under it just
            // collects the same hold once.)
            if case .held = verdict {
                if firstHeld == nil { firstHeld = verdict }
                continue
            }

            // Not substantive on its own, but a better summary than `noRun` — keep the most
            // informative one seen so far and let a later account override it.
            let isQuiet = [
                MigrationStepVerdict.noRun,
                MigrationStepVerdict.deferredToPhase,
                MigrationStepVerdict.idle,
                MigrationStepVerdict.complete
            ].contains(verdict)

            guard isQuiet else { return verdict }
            if fallback == MigrationStepVerdict.noRun { fallback = verdict }
        }

        return firstHeld ?? fallback
    }

    /// The proof budget for one discharge, chosen by PHASE rather than fixed (SDK guidance: each
    /// proof is seconds of CPU, so a session should bound what it takes on and crank again).
    ///
    /// A `.tick` fires every 30 s into a foreground the user is looking at, so it takes the
    /// smallest useful bite; the sync edges are already a working pause and can afford the SDK
    /// example's budget of 4. Nothing is lost by a small budget — proving has no deadline, the
    /// boundary checkpoints are durably retained, and the next pass simply continues.
    private static func proofBudget(for phase: MigrationOpenPhase) -> Int {
        switch phase {
        case MigrationOpenPhase.tick: return 1
        case MigrationOpenPhase.afterSync, MigrationOpenPhase.beforeSync: return 4
        }
    }

    /// SUBMITS THE PREPARATIONS THIS PASS PROVED, in the order the engine proved them.
    ///
    /// The ruling behind this (kris, 2026-08-07): a proved preparation is a complete PCZT
    /// (signatures and proofs); its submission is the ORDINARY path, not the engine's delivery
    /// ceremony — preparations are ZIP 318-exempt, and the engine's own contract is that a
    /// preparation is broadcast as soon as it is proved. So this is not a broadcast session: sync
    /// is not stopped, no `MigrationNetworkPrivacyOptions` are consulted, no broadcast verdict is
    /// produced, and the bytes go out through the same raw-transaction machinery every ordinary
    /// send uses (`submitMigrationPreparation`).
    ///
    /// NO KIND JUDGEMENT LIVES HERE. `txids` is what the prove return handed back, and that return
    /// names preparations ONLY — a transfer's txid never appears in it, and the SDK's accessor
    /// refuses one anyway. The app does not inspect a `kind` to decide anything.
    ///
    /// RETRIEVE AT SUBMISSION TIME, one at a time. The accessor IS the take seam: the wallet's own
    /// record of the transaction binds at retrieval, in the same database transaction that hands
    /// the bytes back. Retrieving the whole list up front would bind every record before the first
    /// submit; retrieving each immediately before its own submit keeps that window as small as the
    /// seam allows. (It is idempotent either way — a crash between retrieve and submit re-retrieves
    /// the same bytes over the same record, and the preparation's ZIP 203 expiry bounds the state
    /// if it is never submitted.)
    ///
    /// ONE FAILURE DOES NOT ABORT THE PASS. A retrieval refusal (a stale txid whose row is no
    /// longer servable) or a submission failure is logged and SKIPPED: the proofs this pass
    /// persisted are already durable, the remaining preparations are independent, and a
    /// preparation that did not go out is re-offered by the engine's own next crank.
    ///
    /// NO TOR-CLASS ROUTING. `broadcastOneTransfer` runs a non-success through
    /// `MigrationBroadcastFailureClass` for its PERSISTENT effects — the Tor-hold indicator, the
    /// pending-prompt latch — because that lane submits under the run's pinned privacy options and
    /// a Tor failure there is a fact about the user's chosen transport. This lane submits over the
    /// app's ordinary connection with no privacy options at all, so it has no Tor verdict to
    /// record and no held prompt to raise; routing a plain server rejection into the Tor UX would
    /// put a privacy claim behind an outcome that made none. What it DOES classify is the SERVER'S
    /// OWN ANSWER — `transferResult(from:)` reads a rejection in the engine's vocabulary, and
    /// `recordPreparationSubmission` records a PERMANENT one so the run can raise attention
    /// instead of re-offering a doomed row forever.
    private func submitProvedPreparations(accountUUID: AccountUUID, txids: [Data]) async {
        guard !txids.isEmpty else { return }

        for txid in txids {
            do {
                let prepared = try await sdkSynchronizer.takeMigrationPreparation(accountUUID, txid)
                // The submit-to-record span wears the transfer session's own in-flight markers —
                // the keep-open banner and the re-entry route's isMigrationWorkInFlight
                // short-circuit both hang off them; see `withPreparationBroadcastMarkers`. `nil`
                // means the account is already mid-broadcast: this row is skipped, the engine
                // re-offers it on its next crank.
                let submitted: Void? = try await withPreparationBroadcastMarkers(accountUUID: accountUUID, id: prepared.id) {
                    let result = try await sdkSynchronizer.submitMigrationPreparation(prepared)
                    LoggerProxy.event(
                        "\(Self.logTag) preparation \(prepared.id) submitted: \(result)"
                    )
                    await recordPreparationSubmission(
                        Self.transferResult(from: result),
                        prepared: prepared,
                        accountUUID: accountUUID
                    )
                }
                if submitted == nil {
                    LoggerProxy.event(
                        """
                        \(Self.logTag) preparation \(prepared.id) not submitted — account already \
                        mid-broadcast; skipped, engine re-offers it
                        """
                    )
                }
            } catch {
                let reason = error.toZcashError()
                LoggerProxy.event(
                    "\(Self.logTag) preparation \(txid.toHexStringTxId()) not submitted — \(reason); skipped, engine re-offers it"
                )
            }
        }
    }

    /// One preparation submission's outcome, recorded where each half belongs — split from the
    /// loop above so the classification's three-way routing reads as the table it is.
    ///
    /// `.success` — TWO records, and only one of them keys on an id.
    ///
    /// The app-side flag is DELIBERATELY NOT `recordTransferBroadcast`. That member is the
    /// schedule-ledger chokepoint for TRANSFERS: it resolves the served transfer id, and a
    /// preparation matches none of its resolution paths (`resolveServedTransferId` considers only
    /// `.transfer`-kind rows, and this lane sets no in-flight marker), so it would fall through to
    /// the storage layer's positional guess and attribute a preparation's submission to the first
    /// unsent schedule TRANSFER. Its `.splitPendingConfirmation` short-circuit ordinarily prevents
    /// that, but only when the migration state READS — an unreadable state (the read throws) lets
    /// the positional guess run. Riding a short-circuit for correctness is not correctness, and
    /// here it is unnecessary: this lane KNOWS the transaction is a preparation, so it performs
    /// exactly what that short-circuit's own doc prescribes for one — mark the had-broadcast flag,
    /// append NO schedule sent record — without asking the state at all.
    ///
    /// The ENGINE's mark is the one no app-side ledger makes. `Proved -> Broadcast` is what
    /// `performMigrationBroadcast`'s success arm does for a transfer; a preparation the app
    /// submitted itself never travels that path, so the app makes the same mark here — KEYED BY
    /// `prepared.id`, the engine transfer id the retrieval handed back, which is the one place in
    /// this lane an id is genuinely load-bearing. The mark gets its OWN catch: by this line the
    /// submission SUCCEEDED, so a mark failure must not log "not submitted" — the engine's
    /// mined-reconciliation still promotes the transaction once the scan sees it.
    ///
    /// `.networkError` — nothing recorded anywhere. The engine's retryable network error records
    /// nothing by design, so reporting it and reporting silence leave the row equally
    /// re-servable; and the app-side flag above is a LANDED-broadcast flag.
    ///
    /// `.invalidNote`/`.expired` — the server PERMANENTLY rejected this preparation, and the
    /// engine is TOLD (the record path's rejection tags date the verdict against the wallet's
    /// observed chain tip and only touch a still-`Proved` row), so the next crank re-adjudicates
    /// satisfiability and can raise Reevaluate/Replan/attention. Without the record the engine
    /// kept re-offering the same doomed row — every prove pass and 30-second tick re-took and
    /// re-submitted it until ZIP 203 expiry, with the user parked in the split phase for hours
    /// and no failure surface. The had-broadcast flag is NOT set: nothing landed.
    private func recordPreparationSubmission(
        _ outcome: MigrationTransferResult,
        prepared: PreparedMigrationTransfer,
        accountUUID: AccountUUID
    ) async {
        switch outcome {
        case MigrationTransferResult.success:
            failureRoutingStorage.markHadBroadcast(for: accountUUID)
            do {
                try await sdkSynchronizer.recordMigrationPreparationBroadcast(accountUUID, prepared, outcome)
            } catch {
                let reason = error.toZcashError()
                LoggerProxy.event(
                    "\(Self.logTag) preparation \(prepared.txid.toHexStringTxId()) submitted; engine mark failed — \(reason); scan promotes it"
                )
            }

        case MigrationTransferResult.networkError:
            // Transport-class non-acceptance: no record anywhere — see the doc above.
            break

        case MigrationTransferResult.invalidNote, MigrationTransferResult.expired:
            do {
                try await sdkSynchronizer.recordMigrationPreparationBroadcast(accountUUID, prepared, outcome)
                LoggerProxy.event(
                    "\(Self.logTag) ⚠ preparation \(prepared.id) permanently rejected (\(outcome)) — recorded; the next crank adjudicates"
                )
            } catch {
                let reason = error.toZcashError()
                LoggerProxy.event(
                    """
                    \(Self.logTag) ⚠ preparation \(prepared.id) permanently rejected (\(outcome)); \
                    engine record failed — \(reason); the next submit attempt re-reports it
                    """
                )
            }
        }
    }

    /// The zcashd `sendrawtransaction` error code for a transaction the node already knows
    /// (`RPC_VERIFY_ALREADY_IN_CHAIN`) — on a rejection it identifies a DUPLICATE re-submission:
    /// the transaction landed on a previous attempt whose response was lost. Mirrors the SDK's
    /// `MigrationBroadcaster.duplicateSubmissionErrorCode` (that type is internal to the SDK, so
    /// its classification is mirrored here rather than imported).
    static let duplicateSubmissionErrorCode = -27

    /// Lowercased message fragments identifying a duplicate re-submission when the server does not
    /// use `duplicateSubmissionErrorCode` — the SDK's
    /// `MigrationBroadcaster.duplicateSubmissionMessageFragments`, mirrored.
    static let duplicateSubmissionMessageFragments = [
        "already in block chain",
        "already in blockchain",
        "txn-already-in-mempool",
        "already in mempool",
        "txn-already-known"
    ]

    /// Lowercased message fragments identifying an expiry-class rejection — the expiry test of the
    /// SDK's `MigrationBroadcaster.map(outcome:successTxId:)`, mirrored.
    static let expiryMessageFragments = ["expired", "tx-expiring-soon"]

    /// The app's ordinary submission result read as the migration engine's outcome vocabulary.
    ///
    /// A `.grpcFailure` is TRANSPORT: no server verdict exists (every endpoint was unreachable,
    /// timed out, or the attempt was cancelled), so nothing is known about the transaction itself
    /// — it maps to the retryable network error, the one outcome that records nothing and leaves
    /// the row offered for the next pass.
    ///
    /// A `.failure` is a SERVER'S VERDICT: `mapSubmissionOutcomes` produces it from a `.rejected`
    /// submission outcome alone, so the submit RPC completed and the server answered. It is
    /// classified by the same rules the SDK's own delivery ceremony applies to a rejection
    /// (`MigrationBroadcaster.map`, whose constants are mirrored above): a duplicate
    /// re-submission means the transaction already landed on an earlier attempt — an acceptance;
    /// an expiry-related message is `.expired`; anything else is `.invalidNote`. The
    /// InvalidNote/Expired split is best-effort, exactly as the SDK's own doc concedes —
    /// lightwalletd's rejection reasons do not cleanly distinguish the two, and the engine's
    /// record path treats both as the same dated terminal report. Collapsing every rejection to a
    /// retryable network error instead — as this function did at first — left a permanently
    /// rejected preparation re-taken and re-submitted by every pass until ZIP 203 expiry, with
    /// the engine never told why nothing moved.
    ///
    /// Internal rather than private so its arms can be pinned directly — the `.partial` arm in
    /// particular is unreachable through `submitProvedPreparations`.
    static func transferResult(
        from result: SDKSynchronizerClient.CreateProposedTransactionsResult
    ) -> MigrationTransferResult {
        switch result {
        case let SDKSynchronizerClient.CreateProposedTransactionsResult.success(txIds):
            return MigrationTransferResult.success(txId: txIds.first ?? "")
        case let SDKSynchronizerClient.CreateProposedTransactionsResult.partial(txIds, _):
            // Unreachable for the single transaction this lane submits (`.partial` needs both an
            // acceptance and a failure), but an acceptance is an acceptance.
            return MigrationTransferResult.success(txId: txIds.first ?? "")
        case let SDKSynchronizerClient.CreateProposedTransactionsResult.failure(txIds, code, description):
            let lowered = description.lowercased()
            if code == Self.duplicateSubmissionErrorCode
                || Self.duplicateSubmissionMessageFragments.contains(where: { lowered.contains($0) }) {
                return MigrationTransferResult.success(txId: txIds.first ?? "")
            }
            if Self.expiryMessageFragments.contains(where: { lowered.contains($0) }) {
                return MigrationTransferResult.expired
            }
            return MigrationTransferResult.invalidNote
        case SDKSynchronizerClient.CreateProposedTransactionsResult.grpcFailure:
            return MigrationTransferResult.networkError(retryable: true)
        }
    }

    /// One action, executed. The switch is exhaustive over `MigrationStepAction` (I1) — every case
    /// the planner can produce has a body here, and adding a case to either breaks the build.
    // swiftlint:disable:next cyclomatic_complexity
    private func execute(
        _ action: MigrationStepAction,
        accountUUID: AccountUUID,
        phase: MigrationOpenPhase,
        isPreparationBroadcast: Bool = false
    ) async -> MigrationStepVerdict {
        switch action {
        case let MigrationStepAction.broadcast(instruction):
            if phase == MigrationOpenPhase.tick {
                // MOB-1466: a tick that reaches a broadcast action is a genuine, tick-triggered
                // network event — the same kind of thing an app-open's own `.beforeSync` session
                // already is — so it gets its own `[MIG]` session marker, distinguishing it from
                // the ambient foreground session it interrupts. `tip` comes from the exact source
                // every other `beginSession` call site uses (`sdkSynchronizer.latestState()`); the
                // driver already depends on `sdkSynchronizer` for the engine reads above, so no new
                // seam is needed to reach it. Begun here rather than only once the broadcast lands:
                // "about to attempt" is the trigger, not "succeeded" — `executeBroadcast` below may
                // still hold this (mode belt, manual delivery, the buffer), and that hold is itself
                // worth its own session-scoped log lines.
                MigrationTrace.beginSession(cause: MigrationTrace.Cause.timer, tip: sdkSynchronizer.latestState().latestBlockHeight)
            }
            return await executeBroadcast(
                instruction: instruction,
                accountUUID: accountUUID,
                phase: phase,
                isPreparation: isPreparationBroadcast
            )

        case let MigrationStepAction.prove(instruction):
            // FIND-5 refinement: a `.tick` never RE-RUNS a sweep already adjudicated stalled. The
            // stall verdict means the engine reported rows ready and two consecutive sweeps proved
            // nothing — burning a full sweep (DB-actor traffic, cache warm-ups, pokes) every 30s
            // against that same contradiction is pure heat. The open lanes deliberately keep
            // retrying at their edges: each sync gives the engine fresh data and the stall an
            // honest chance to clear.
            if phase == MigrationOpenPhase.tick, isProvingStalled {
                return MigrationStepVerdict.needsUser(MigrationStepBlocker.provingStalled)
            }
            // PER-ACCOUNT AND INSTRUCTED (2026-08-07): the executor proves the rows THIS
            // account's crank named, so the pass is scoped to this account's own batch rather than
            // walking every candidate. The budget is chosen by phase — a 30 s tick takes on less
            // than a post-sync edge, since each proof is seconds of CPU and the run loses nothing
            // by deferring (boundary checkpoints are durably retained).
            let outcome = await runProveSweep(
                accountUUID: accountUUID,
                instruction: instruction,
                maxProofs: Self.proofBudget(for: phase)
            )
            // THE PREPARATIONS THIS PASS PROVED GO OUT IN THIS PASS (kris, 2026-08-07). See
            // `submitProvedPreparations`. This is what supersedes the interim next-crank prep
            // delivery the previous commit settled for.
            await submitProvedPreparations(accountUUID: accountUUID, txids: outcome.preparationTxids)
            let proved = outcome.totalProved
            await reconcile()
            if proved == 0 && isProvingStalled {
                // I3: the engine says these rows are ready and the sweep proves none of them, twice
                // running. Staying in the app does not help, so the app stops asking the user to —
                // and says so rather than leaving a spinner up.
                return MigrationStepVerdict.needsUser(MigrationStepBlocker.provingStalled)
            }
            // ONE INSTRUCTION, ONE ACTION. The pass ends at the proof plus the submissions the
            // proof itself authorized: nothing is re-cranked and nothing is chained. A TRANSFER's
            // broadcast is still the next wake-up's business, because only a `.broadcast`
            // instruction can sanction one.
            //
            // D2 (danny + nuttycom, 2026-08-05) — "prove and broadcast a preparation in the same
            // pass" — is honoured again, by the seam that replaced its blocked route. What blocked
            // it was that a broadcast needs an opaque `MigrationBroadcastInstruction` a prove batch
            // does not contain; the prove return now names the preparations directly, so nothing
            // has to be fabricated and no app-side kind judgement is reintroduced — the SDK's
            // return and its preparation gate carry it.
            return MigrationStepVerdict.proved(count: proved)

        case let MigrationStepAction.rebuild(id):
            return await executeRebuild(id: id, accountUUID: accountUUID)

        case MigrationStepAction.replan:
            // The engine named it outright — no sync, no id, no inference. The hand-off is the
            // one the retired escalate arm used to make (the banner reads "Update migration plan" and the
            // re-entry route lands on the re-plan lane); what differs is that it happens on the
            // FIRST answer rather than after a wasted pass, and the log line can say why without
            // naming a transaction the engine never named.
            LoggerProxy.event(
                "\(Self.logTag) ⚠ engine answered REPLAN — this run's plan can no longer cover its balance; handing off for a fresh plan"
            )
            await reconcile()
            return MigrationStepVerdict.needsUser(MigrationStepBlocker.runNeedsReplan)

        case MigrationStepAction.reevaluate:
            // The engine is telling us OUR chain view is behind the node that rejected a broadcast.
            // The whole discharge is to let this session sync; the next ask adjudicates. Nothing is
            // surfaced to the user and nothing is reconciled — no determination has been made yet,
            // so there is no state change for the surfaces to re-read.
            LoggerProxy.event(
                "\(Self.logTag) engine answered REEVALUATE — a broadcast was rejected by a node ahead of us; syncing and re-asking"
            )
            return MigrationStepVerdict.reevaluating

        case MigrationStepAction.armWakeups:
            // Arming happens unconditionally in `advance` above; this case exists so `.waiting` has
            // a name in the verdict rather than falling into a catch-all.
            return MigrationStepVerdict.idle

        case MigrationStepAction.finish:
            return MigrationStepVerdict.complete

        case let MigrationStepAction.nothing(hold):
            switch hold {
            case MigrationStepHold.wrongPhase:
                return MigrationStepVerdict.deferredToPhase
            case MigrationStepHold.noRun:
                _ = phase
                return MigrationStepVerdict.noRun
            }
        }
    }

    /// `.broadcast` — delegates to the existing headless send session, which owns the privacy
    /// buffer, the manual-delivery opt-out, the network snapshot and the failure routing.
    ///
    /// The driver deliberately does NOT reimplement any of that. It only translates the outcome
    /// into a verdict, so that "held by the buffer" stops looking like "did nothing". `phase` is
    /// threaded through (rather than read from a stored property) so `MigrationStepPlan` stays
    /// pure — the plan already decided this action is due; this is the one place that still needs
    /// to know WHICH phase asked, for the mode belt below.
    private func executeBroadcast(
        instruction: MigrationBroadcastInstruction,
        accountUUID: AccountUUID,
        phase: MigrationOpenPhase,
        isPreparation: Bool = false
    ) async -> MigrationStepVerdict {
        // MOB-1466: THE MODE BELT. A tick is a broadcast opportunity ONLY for a run the user chose
        // to run on a schedule (`.privateScheduled`) — see `MigrationStepPlan`'s tick-column doc. An
        // `.immediate` run still gets its one delivery from the open lanes (`.beforeSync`); ticking
        // it too would send the moment Ironwood activates rather than at the user's own chosen
        // pace, on whatever 30s boundary the app happened to be foregrounded across. Checked BEFORE
        // the manual-delivery read below: an immediate-mode account is never manual-delivery's
        // business to begin with, and ordering it first keeps "why this tick held" from ever being
        // misread as the user's own delivery preference.
        //
        // AUD-3: the belt is a TRANSFER pacing choice — a note-PREPARATION is wallet plumbing on
        // the engine's own schedule, exempt regardless of mode.
        if phase == MigrationOpenPhase.tick,
            !isPreparation,
            migrationMode(accountUUID: accountUUID) != MigrationMode.privateScheduled {
            return MigrationStepVerdict.held(reason: "immediate-mode run — ticks leave it to the open lanes")
        }

        // (The manual-delivery hold that lived here was REMOVED 2026-08-07 with the whole
        // manual-tap send surface — every account is auto-delivery now.)

        // AUD-3's post-sync buffer hold stood here, transfer-only (ZIP 318 exempts a preparation:
        // it is a fully shielded send-to-self whose own wake-up IS a sync session, so consulting
        // the buffer held every single prep by construction). Deleted 2026-08-07 with the buffer —
        // a fixed sync->broadcast delay is an identifiable pattern, so nothing times this lane now.
        // `isPreparation` still governs the mode belt above and the session-separation cell in
        // `MigrationStepPlan`, so it stays a parameter.

        // The account THIS discharge vetted (mode belt, manual delivery, send gate above) is the
        // one the session delivers — see `runBroadcastSession(vettedAccountUUID:)`'s doc for the
        // held-account submission its own sweep used to make.
        let didBroadcast = await runBroadcastSession(
            accountUUID: accountUUID,
            instruction: instruction,
            vettedPreparationDelivery: isPreparation
        )
        // The VERDICT keeps a plain id on purpose: it is a log/observation value the app owns, not
        // a capability. Only the ACTION carries the instruction.
        return didBroadcast
            ? MigrationStepVerdict.broadcast(id: instruction.id)
            : MigrationStepVerdict.held(reason: "broadcast session submitted nothing for transfer \(instruction.id)")
    }

    /// `.rebuild` — the step that used to deadlock the hardest, because its only discharge in the
    /// whole app was a button on a screen nothing routed to.
    ///
    /// A software account rebuilds AUTOMATICALLY here. The engine's contract for a rebuild is that
    /// the elapsed rows are re-anchored IN PLACE with unchanged amounts — there is no new consent
    /// decision to take the user through, so making them tap through one was never protecting
    /// anything, it was just the only code path that existed. `exportWallet()` is a plain keychain
    /// read on iOS, so this raises no authentication prompt.
    ///
    /// A Keystone account cannot: its rebuilt rows come back unsigned and need the signing ceremony,
    /// which is genuinely the user's. That is recorded as a blocker (I3), never silently dropped.
    private func executeRebuild(id: UInt32, accountUUID: AccountUUID) async -> MigrationStepVerdict {
        let account = walletAccounts.first { $0.id == accountUUID }

        guard account?.vendor != WalletAccount.Vendor.keystone else {
            LoggerProxy.event(
                "\(Self.logTag) transfer \(id) expired on a Keystone account — the rebuilt batch needs a signing ceremony"
            )
            return MigrationStepVerdict.needsUser(MigrationStepBlocker.rebuildNeedsSignature(id: id))
        }

        guard let zip32AccountIndex = account?.zip32AccountIndex else {
            // A software account with no ZIP 32 index is a "can't happen". It routes to the user
            // rather than to a silent no-op, because a can't-happen that stalls a run forever is
            // strictly worse than one that shows a screen.
            return MigrationStepVerdict.needsUser(MigrationStepBlocker.rebuildNeedsSignature(id: id))
        }

        do {
            let usk = try await MigrationSpendingKeyDerivation.deriveUSK(
                zip32AccountIndex: zip32AccountIndex,
                walletStorage: walletStorage,
                mnemonic: mnemonic,
                derivationTool: derivationTool,
                networkType: zcashSDKEnvironment.network().networkType
            )
            let schedule = try await sdkSynchronizer.refreshStaleMigrationTransfers(accountUUID, usk)
            // Persist the RETURNED schedule as committed truth BEFORE reconcile, exactly as the
            // Recovery screen's lane does: the SDK keeps no app-facing schedule post-refresh, so
            // without this the app would keep rendering the stale pre-refresh heights.
            await recordCommittedSchedule(accountUUID: accountUUID, schedule: schedule)
            await reconcile()
            LoggerProxy.event("\(Self.logTag) rebuilt expired transfer \(id) in place — no user action was needed")
            return MigrationStepVerdict.rebuilt(id: id)
        } catch {
            // A failed automatic rebuild is not a dead end: the Recovery screen's own button runs
            // the same call with the user present, so route them to it rather than retrying blind.
            LoggerProxy.event("\(Self.logTag) automatic rebuild of transfer \(id) failed: \(error.toZcashError())")
            return MigrationStepVerdict.needsUser(MigrationStepBlocker.rebuildNeedsSignature(id: id))
        }
    }
}
