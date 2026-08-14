//
//  MigrationSchedulingPhaseTests.swift
//  zodlTests
//
//  The Scheduling screen — the loading twin of "Migration Scheduled" (MOB-1466, Lukas 2026-08-07).
//
//  WHY THIS EXISTS AT ALL. The commit's sign+store is fast; the ~30 s is the run's awaited FIRST
//  DRIVE (`MigrationTransferPlan`'s `.scheduleCommitted` → `.scheduleSigned` leg). That wait used to
//  happen on the plan screen under a button spinner: "I tap start migration and there is a
//  spinner… I'm locked on left screen and after 30s land to the right one." The Figma's middle
//  frame was never built — no file, no string, no commit in any branch. It is built now.
//
//  WHAT THESE PINS PROTECT. The phase is an ENUM, not an `isLoading` bool beside four value fields,
//  precisely so a future reader cannot render a summary that does not exist yet. If someone
//  "simplifies" `Phase` back into a flag, `schedulingCarriesNoSummary` is what fails.
//

import Foundation
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationSchedulingPhaseTests {
    /// The whole point of the enum: while scheduling there are NO numbers, and the view has no way
    /// to reach any. A bool-plus-fields shape would leave four zeros sitting in state for a row to
    /// render as "0.000 ZEC / 0 of 0 / ~0 hours" — four confident lies under a spinner.
    @Test func schedulingCarriesNoSummary() {
        let state = MigrationScheduled.State(phase: .scheduling)

        #expect(state.isScheduling)
        #expect(state.summary == nil)
    }

    /// The hydrated shape, reached through the convenience init every existing call site uses —
    /// kept deliberately so adding the phase changed no caller.
    @Test func hydratedInitProducesReady() {
        let state = MigrationScheduled.State(
            totalAmount: Zatoshi(1_245_800_000),
            sentCount: 2,
            totalCount: 6,
            durationHours: 36
        )

        #expect(!state.isScheduling)
        #expect(state.summary?.totalAmount == Zatoshi(1_245_800_000))
        #expect(state.summary?.sentCount == 2)
        #expect(state.summary?.totalCount == 6)
        #expect(state.summary?.durationHours == 36)
    }

    /// The coordinator's own builder is the HYDRATED path and must never produce a scheduling
    /// screen: it is called at `.confirmed` (and by the recovery refresh-stale push), by which
    /// point every number is in hand. A `.scheduling` result here would mean a screen that spins
    /// forever, because nothing arrives after it to fill in.
    @Test func scheduledStateNowIsAlwaysReady() {
        let state = MigrationCoordFlow.scheduledStateNow(schedule: nil, snapshot: nil)

        #expect(!state.isScheduling)
        #expect(state.summary != nil)
    }

    /// Equatable has to separate the two phases — the coordinator's hydrate-in-place step tests
    /// `existing.isScheduling` to decide "fill this element in" vs "push a new one", and TCA's own
    /// state diffing decides whether the skeleton actually redraws as values.
    @Test func phasesAreDistinct() {
        let scheduling = MigrationScheduled.State(phase: .scheduling)
        let ready = MigrationScheduled.State(totalAmount: Zatoshi.zero, sentCount: 0, totalCount: 0, durationHours: 0)

        #expect(scheduling != ready)
        #expect(scheduling == MigrationScheduled.State(phase: .scheduling))
    }

    /// A ready phase whose numbers happen to be zero is STILL ready — the distinction is provenance
    /// (has the drive returned?), never the values. Pinned because "summary == nil when everything
    /// is zero" is exactly the shortcut that would re-introduce the spinner-that-never-ends.
    @Test func allZeroSummaryIsStillReady() {
        let state = MigrationScheduled.State()

        #expect(!state.isScheduling)
        #expect(state.summary != nil)
    }
}
