//
//  MigrationETAPhrasingTests.swift
//  zodlTests
//
//  Pins `MigrationETA.caption(minutesFromNow:phrasing:)` across all three `Phrasing` cases —
//  MOB-1466 (field finding O5) adds `.plan`, the PRE-COMMIT Transfer Plan screen's committal,
//  future-tense phrasing ("Starts right away" / "Starts in ~N mins" / "Starts in ~N hours"),
//  alongside the two that already shipped: `.bare` (every POST-COMMIT forward surface — Migration
//  Status/Progress/Resume — which this task must NOT change so much as a character of) and
//  `.inPrefixed` (unused by any screen after this task rewires every PRE-COMMIT call site to
//  `.plan`, but still a real, documented case worth pinning directly on its own merits — the same
//  "pin the branch even when only one is reachable through a caller today" precedent
//  `MigrationCoordFlow.transferRowStatus`'s own doc follows).
//
//  No suite existed yet for `MigrationETA.caption` itself — `MigrationChainClockTests` covers
//  `minutesFromNow`/`bucketed`, and `MigrationPrepareBalanceTests` calls `caption` only
//  incidentally, to build its own expected value. This is the first suite dedicated to the shared
//  caption formatter.
//

import Testing
@testable import zodl_internal

@Suite struct MigrationETAPhrasingTests {
    // MARK: - .bare — every POST-COMMIT forward surface (MigrationStatusView). MOB-1466 must not
    // change this phrasing at all; pinned against both the generated accessor AND the literal
    // English copy, so a routing regression and an accidental catalog edit both fail loudly.

    /// MOB-1466 (Lukas's ruling, 2026-08-08): an ARRIVED window on a post-commit surface says
    /// "Recomputing ETA…", not "Ready now" — there is no "ready now" PHASE, and the frames have
    /// the string only in the `.replan` and expiry flows. The engine's overdue re-spread gives
    /// every pending row a new height on the next `advance_migration`, so this states a real gap
    /// rather than inviting an action ZIP 318 permits only one row to take.
    @Test func bareArrivedWindowSaysRecomputing() {
        let caption = MigrationETA.caption(minutesFromNow: 0, phrasing: .bare)
        #expect(caption == String(localizable: .migrationPlanEtaRecomputing))
        #expect(caption == "Recomputing ETA…")
    }

    /// The same answer the UNKNOWN-TIP case gives, and deliberately so: both are "no forward time
    /// to state, one is coming". If these ever diverge, one of the two situations has quietly
    /// grown a second meaning.
    @Test func arrivedAndUnknownTipGiveTheSameBareAnswer() {
        #expect(
            MigrationETA.caption(minutesFromNow: 0, phrasing: .bare)
                == MigrationETA.caption(minutesFromNow: nil, phrasing: .bare)
        )
    }

    @Test(arguments: [1, 30, 59]) func bareMinutesHasNoStartsOrInPrefix(minutes: Int) {
        let caption = MigrationETA.caption(minutesFromNow: minutes, phrasing: .bare)
        #expect(caption == String(localizable: .migrationPlanEtaMins(minutes)))
        #expect(caption == "~\(minutes) mins")
    }

    @Test(arguments: [60, 90, 720]) func bareHoursHasNoStartsOrInPrefix(minutesFromNow: Int) {
        let hours = minutesFromNow / 60
        let caption = MigrationETA.caption(minutesFromNow: minutesFromNow, phrasing: .bare)
        #expect(caption == String(localizable: .migrationPlanEtaHours(hours)))
        #expect(caption == "~\(hours) hours")
    }

    // MARK: - .inPrefixed — kept pinned as a real, still-supported case even though no screen calls
    // it with this phrasing after MOB-1466 rewires the pre-commit screen to `.plan`.

    @Test func inPrefixedArrivedWindowSaysRecomputing() {
        // The arrived bucket has only one non-`.plan` rendering, and it takes no "in ~" prefix:
        // there is no number to prefix. Same answer whichever of the two post-commit phrasings
        // asked for it.
        #expect(MigrationETA.caption(minutesFromNow: 0, phrasing: .inPrefixed) == "Recomputing ETA…")
    }

    @Test(arguments: [1, 30, 59]) func inPrefixedMinutesLeadsWithIn(minutes: Int) {
        let caption = MigrationETA.caption(minutesFromNow: minutes, phrasing: .inPrefixed)
        #expect(caption == String(localizable: .migrationPlanEtaMinsIn(minutes)))
        #expect(caption == "in ~\(minutes) mins")
    }

    @Test(arguments: [60, 90, 720]) func inPrefixedHoursLeadsWithIn(minutesFromNow: Int) {
        let hours = minutesFromNow / 60
        let caption = MigrationETA.caption(minutesFromNow: minutesFromNow, phrasing: .inPrefixed)
        #expect(caption == String(localizable: .migrationPlanEtaHoursIn(hours)))
        #expect(caption == "in ~\(hours) hours")
    }

    // MARK: - .plan — MOB-1466: the PRE-COMMIT Transfer Plan screen's committal, future-tense
    // phrasing (field finding O5 — "Ready now" read as "already running" before Confirm was ever
    // tapped, 8/8 times). Wired at `MigrationTransferPlanView.forwardETA(for:)`,
    // `MigrationTransferPlan.State.splitCaption`, and `MigrationPrepareBalanceSheet`'s per-step
    // caption — every caption this one pre-commit screen renders, so nothing on it is left reading
    // "Ready now" beside a "Starts right away" sibling.

    @Test func planReadyNowStartsRightAway() {
        let caption = MigrationETA.caption(minutesFromNow: 0, phrasing: .plan)
        #expect(caption == String(localizable: .migrationPlanStartsRightAway))
        #expect(caption == "Starts right away")
    }

    @Test(arguments: [1, 30, 59]) func planMinutesStartsIn(minutes: Int) {
        let caption = MigrationETA.caption(minutesFromNow: minutes, phrasing: .plan)
        #expect(caption == String(localizable: .migrationPlanStartsInMins(minutes)))
        #expect(caption == "Starts in ~\(minutes) mins")
    }

    @Test(arguments: [60, 90, 720]) func planHoursStartsIn(minutesFromNow: Int) {
        let hours = minutesFromNow / 60
        let caption = MigrationETA.caption(minutesFromNow: minutesFromNow, phrasing: .plan)
        #expect(caption == String(localizable: .migrationPlanStartsInHours(hours)))
        #expect(caption == "Starts in ~\(hours) hours")
    }

    // MARK: - The bucket boundary is phrasing-independent. `MigrationChainClockTests` already pins
    // `bucketed` itself; this only confirms `caption` routes `.plan` through the SAME boundary
    // rather than smuggling in a second one.

    @Test func planBucketsAtSixtyMinutesLikeEveryOtherPhrasing() {
        #expect(MigrationETA.caption(minutesFromNow: 59, phrasing: .plan) == String(localizable: .migrationPlanStartsInMins(59)))
        #expect(MigrationETA.caption(minutesFromNow: 60, phrasing: .plan) == String(localizable: .migrationPlanStartsInHours(1)))
    }
}
