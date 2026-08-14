//
//  MigrationETA.swift
//  zodl
//
//  Central forward-looking relative-time helper for the Orchard -> Ironwood migration surfaces
//  (MOB-1513 B3). Every screen that captions a PENDING/active transfer's ETA — Transfer Plan,
//  Migration Status/Progress, Resume — routes through this one type so the granularity (Ready now /
//  in ~N mins / in ~N hours) stays consistent.
//
//  Root cause it replaces: the row builders converted a transfer's execution height to a relative
//  time via `sdkSynchronizer.estimateTimestamp(height)`, which snaps to the nearest BUNDLED
//  CHECKPOINT at-or-below the height and returns `nil` for any height beyond the newest shipped
//  checkpoint (all FUTURE migration heights). A `nil` timestamp floored to `0` hours, which the
//  caption rendered as the hardcoded "~10 mins" fallback (`migrationPlanEtaFirst`) on every row. A
//  block delta is precise regardless of checkpoint staleness — the same correction
//  `MigrationCoordFlowCoordinator.liveStalledHoursAgo` already applied for the BACKWARD
//  ("N hours ago") direction. Android parity: `MigrationDurationFormat.kt` does the same
//  `(toHeight − fromHeight) × BLOCK_INTERVAL`.
//
//  P3: the frame that delta is measured in moved into `MigrationChainClock` — the SDK's estimated
//  tip and MEASURED block rate, rather than the scanned tip and a fixed 75 s. See that type's
//  header for why each half matters.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// A pending transfer's forward ETA, bucketed into the three granularities the migration surfaces
/// render. PAST labels ("Sent Nh ago", "Overdue Nh ago") are NOT modelled here — they keep their
/// own backward-looking timestamp lookups.
enum MigrationETA: Equatable, Sendable {
    case readyNow
    case minutes(Int)
    case hours(Int)

    /// Minutes-from-now for a transfer's scheduled execution height, via a block delta measured in
    /// `clock`'s frame: `(scheduledHeight − tip) × secondsPerBlock ÷ 60`, floored, never negative.
    ///
    /// `nil` WHEN THE TIP IS UNKNOWN (MOB-1466, Lukas 2026-08-07: "either we know Tx send height =>
    /// ETAs or we don't.. if we don't we need to write 'recomputing ETA...'").
    ///
    /// This returned `0` for an unknown tip until now, described as a fail-safe sentinel — and the
    /// arithmetic reasoning was right (an unknown tip is not a low one, so it must not be subtracted
    /// from). The DISPLAY consequence was not: `bucketed` reads `<= 0` as `.readyNow`, so a cold
    /// launch (`tip 0`) rendered "Ready now" on every pending transfer — eleven instructions to act,
    /// from a clock with nothing to measure against, replaced by real times seconds later.
    ///
    /// Zero and nil now mean different things and neither is a guess: `0` is "at or behind a KNOWN
    /// tip" (genuinely ready), `nil` is "no tip, no answer".
    ///
    /// P3: the tip and the rate travel together in `MigrationChainClock` — see that type for why
    /// both are read from the SDK's measured estimators rather than the scanned tip and a hardcoded
    /// 75 s.
    static func minutesFromNow(scheduledHeight: BlockHeight, clock: MigrationChainClock) -> Int? {
        guard clock.isTipKnown else { return nil }
        return max(0, Int((clock.secondsUntil(height: scheduledHeight) / 60).rounded(.down)))
    }

    /// Minutes SINCE a scheduled height passed — the overdue mirror of `minutesFromNow`, which
    /// clamps at 0. 0 when the height is still in the future.
    static func overdueMinutes(scheduledHeight: BlockHeight, clock: MigrationChainClock) -> Int {
        max(0, Int((-clock.secondsUntil(height: scheduledHeight) / 60).rounded(.down)))
    }

    /// Buckets a minutes-from-now value into the display granularity: `<= 0` -> Ready now, `1..<60`
    /// -> minutes, `>= 60` -> hours (floored).
    static func bucketed(minutesFromNow minutes: Int) -> MigrationETA {
        guard minutes > 0 else { return .readyNow }
        return minutes < 60 ? .minutes(minutes) : .hours(minutes / 60)
    }

    /// Whether a caption uses the Transfer Plan scheduled variant's "in ~…" phrasing, the bare
    /// "~…" phrasing every other POST-COMMIT forward surface uses (Transfer Plan manual/recreated,
    /// Migration Status/Progress, Resume), or `.plan`'s own committal phrasing.
    ///
    /// MOB-1466 (field finding O5): `.plan` is unrelated to the other two cases' ETA framing — it's
    /// the PRE-COMMIT Transfer Plan screen's own future/committal tense ("Starts right away" /
    /// "Starts in ~N mins"), added because the screen's live-state language ("Ready now") read as
    /// "migration already running" before Confirm was ever tapped, and an unconfirmed user was
    /// indistinguishable from one who chose not to migrate. Every POST-COMMIT surface keeps
    /// `.bare`/`.inPrefixed` completely unchanged — see `MigrationETAPhrasingTests`.
    enum Phrasing: Equatable, Sendable {
        case inPrefixed
        case bare
        case plan
    }

    /// The localized forward-ETA caption for `minutesFromNow`, bucketed then rendered under the
    /// requested phrasing. The single caption formatter every forward surface calls — see this
    /// type's header for why one shared formatter matters.
    /// `nil` minutes = the tip is unknown, so there is no ETA to state — every phrasing says
    /// "Recomputing ETA…" (Lukas's own copy, 2026-08-07). This is the ONE place the unknown-tip
    /// answer is rendered, so no surface can accidentally fall back to a number.
    ///
    /// A row with no forward time AT ALL (a finished one) must not reach here — it renders its green
    /// check and DONE label with no ETA line, per Lukas's ruling. That absence is the caller's to
    /// express, not this formatter's: "recomputing" on a completed transfer would be its own lie.
    ///
    /// MOB-1466 (Lukas's ruling, 2026-08-08): A POST-COMMIT ROW WHOSE WINDOW HAS ARRIVED SAYS
    /// "Recomputing ETA…", NOT "Ready now". Checking the frames, "Ready now" appears in no
    /// post-commit screen — only the `.replan` and expiry flows — because there is no such PHASE.
    /// Lukas's own statement of the ladder: a prepared transfer says "~X", a passed one is overdue,
    /// "there is no phase at all saying ready now". What put it on six rows at once was arithmetic,
    /// not design: `bucketed` reads `<= 0` as `.readyNow`, and `minutesFromNow` clamps at zero, so
    /// a height three hours behind the tip is indistinguishable from one due this second. Sleep
    /// through part of a schedule and every passed row claims to be actionable — while ZIP 318
    /// permits exactly one broadcast at a time, so all but one of those invitations is refused by
    /// the engine.
    ///
    /// "Recomputing" is the TRUE word for that state rather than a softer one. The engine's overdue
    /// re-spread ("at most one overdue transfer is released immediately; the rest are re-spread")
    /// raises EVERY pending scheduled height by the lag, judged at the estimated target so it runs
    /// before the wallet syncs — so on the very next `advance_migration` these rows really do get
    /// new times. The label states the gap between opening the app and that shift landing.
    ///
    /// `.plan` keeps "Starts right away". It is PRE-COMMIT, its own committal tense, and a real
    /// designed frame — see `Phrasing.plan`'s doc for why it exists. This ruling is about the
    /// post-commit surfaces; deleting the plan screen's string with them would be collateral.
    static func caption(minutesFromNow minutes: Int?, phrasing: Phrasing) -> String {
        guard let minutes else {
            return String(localizable: .migrationPlanEtaRecomputing)
        }
        switch bucketed(minutesFromNow: minutes) {
        case .readyNow:
            return phrasing == .plan
                ? String(localizable: .migrationPlanStartsRightAway)
                : String(localizable: .migrationPlanEtaRecomputing)
        case .minutes(let mins):
            switch phrasing {
            case .inPrefixed:
                return String(localizable: .migrationPlanEtaMinsIn(mins))
            case .bare:
                return String(localizable: .migrationPlanEtaMins(mins))
            case .plan:
                return String(localizable: .migrationPlanStartsInMins(mins))
            }
        case .hours(let hrs):
            switch phrasing {
            case .inPrefixed:
                return String(localizable: .migrationPlanEtaHoursIn(hrs))
            case .bare:
                return String(localizable: .migrationPlanEtaHours(hrs))
            case .plan:
                return String(localizable: .migrationPlanStartsInHours(hrs))
            }
        }
    }
}
