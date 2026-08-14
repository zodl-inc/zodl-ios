//
//  MigrationPrepareBalanceTests.swift
//  zodlTests
//
//  Covers the collapsed-split behaviour introduced with the "Prepare Your Balance" sheet
//  (Figma 5207:16024): `MigrationTransferPlan.State.splitRows` / `hasMultiStepSplit` /
//  `splitCaption`, and the sheet's own `stateCaption(for:)` phrasing.
//
//  Worth pinning because this REPLACED a shipped behaviour. D14 rendered one timeline row per
//  preparation transaction; the design collapses them to one. The collapse is what lets the row
//  carry the split's real total again — D14 had to blank the amount column across several rows,
//  since no honest per-preparation amount exists to divide the total into.
//

import ComposableArchitecture
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationPrepareBalanceTests {
    // MARK: - Fixtures

    private static func row(_ index: Int, amount: Zatoshi?) -> MigrationTransferRow {
        MigrationTransferRow(
            id: "\(index)",
            index: index,
            amount: amount,
            status: .pending,
            hoursFromNow: (index + 1) * 6
        )
    }

    private static func state(
        rows: [MigrationTransferRow],
        preparationCount: Int
    ) -> MigrationTransferPlan.State {
        var state = MigrationTransferPlan.State(
            variant: .scheduled,
            rows: IdentifiedArrayOf(uniqueElements: rows),
            totalDurationHours: 36
        )
        state.preparationCount = preparationCount
        return state
    }

    private static let threeRows = [
        row(0, amount: Zatoshi(1_000_000_000)),
        row(1, amount: Zatoshi(200_000_000)),
        row(2, amount: Zatoshi(45_000_000))
    ]

    // MARK: - The collapse

    /// The behaviour D14 got wrong: however many preparation transactions the engine reports, the
    /// plan timeline shows exactly ONE split row.
    @Test(arguments: [1, 2, 4, 9]) func splitCollapsesToOneRowAtAnyPreparationCount(count: Int) {
        let state = Self.state(rows: Self.threeRows, preparationCount: count)
        #expect(state.splitRows.count == 1)
        #expect(state.splitRows.first?.kind == .splitBalance)
    }

    /// The payoff of collapsing: one row can honestly carry the whole split's value.
    @Test func collapsedRowCarriesTheTotalEvenForAMultiStepSplit() {
        let state = Self.state(rows: Self.threeRows, preparationCount: 4)
        #expect(state.splitRows.first?.amount == Zatoshi(1_245_000_000))
    }

    /// Honest-or-nothing: one unknown transfer amount makes the TOTAL unknown, and an unknown total
    /// shows no amount rather than a wrong one.
    @Test func unknownTransferAmountMakesTheTotalUnknown() {
        let rows = [
            Self.row(0, amount: Zatoshi(1_000_000_000)),
            Self.row(1, amount: nil)
        ]
        #expect(Self.state(rows: rows, preparationCount: 1).splitRows.first?.amount == nil)
    }

    /// No schedule yet — nothing to split, so no row at all (not a zero-valued one).
    @Test func noTransfersMeansNoSplitRow() {
        #expect(Self.state(rows: [], preparationCount: 3).splitRows.isEmpty)
    }

    // MARK: - The disclosure gate

    @Test func singleTransactionSplitOffersNoDisclosure() {
        #expect(!Self.state(rows: Self.threeRows, preparationCount: 1).hasMultiStepSplit)
    }

    @Test func multiTransactionSplitOffersTheDisclosure() {
        #expect(Self.state(rows: Self.threeRows, preparationCount: 4).hasMultiStepSplit)
    }

    // MARK: - Caption

    /// A one-transaction split reads exactly as it did before the collapse — no step suffix.
    ///
    /// MOB-1466: `.plan`, not `.inPrefixed` — this state is ALWAYS the pre-commit Transfer Plan
    /// screen (regardless of `variant`), so its split row takes the same committal, future-tense
    /// phrasing every other caption on this screen does now. See `MigrationETAPhrasingTests` for
    /// the phrasing itself; this only pins that `splitCaption` routes through it.
    @Test func singleStepCaptionIsThePlanPhrasedETA() {
        let state = Self.state(rows: Self.threeRows, preparationCount: 1)
        #expect(state.splitCaption == MigrationETA.caption(minutesFromNow: 0, phrasing: .plan))
    }

    @Test func multiStepCaptionAppendsTheStepCount() {
        let state = Self.state(rows: Self.threeRows, preparationCount: 4)
        let eta = MigrationETA.caption(minutesFromNow: 0, phrasing: .plan)
        #expect(state.splitCaption == String(localizable: .migrationPlanSplitBalanceCaption(eta, 4)))
        #expect(state.splitCaption != eta)
    }

    // MARK: - Step state phrasing

    @Test func singleDependencyReadsAsOneStep() {
        #expect(
            MigrationPrepareBalanceSheet.stateCaption(for: .waitsOn([3]))
                == String(localizable: .migrationPrepareWaitsOnStep(3))
        )
    }

    /// The design's own step 3, "Waits on steps 1 & 2" — the case the interim ladder never produces
    /// but real `depends_on` data will.
    @Test func twoDependenciesJoinWithAnAmpersand() {
        #expect(
            MigrationPrepareBalanceSheet.stateCaption(for: .waitsOn([1, 2]))
                == String(localizable: .migrationPrepareWaitsOnSteps("1 & 2"))
        )
    }

    @Test func threeDependenciesUseCommasThenAnAmpersand() {
        #expect(
            MigrationPrepareBalanceSheet.stateCaption(for: .waitsOn([1, 2, 3]))
                == String(localizable: .migrationPrepareWaitsOnSteps("1, 2 & 3"))
        )
    }

    @Test func dependenciesAreSortedBeforeRendering() {
        #expect(
            MigrationPrepareBalanceSheet.stateCaption(for: .waitsOn([3, 1, 2]))
                == MigrationPrepareBalanceSheet.stateCaption(for: .waitsOn([1, 2, 3]))
        )
    }

    /// "Waits on nothing" is not an actionable state; it must not render an empty trailing column.
    @Test func emptyDependencyListFallsBackToInFlight() {
        #expect(
            MigrationPrepareBalanceSheet.stateCaption(for: .waitsOn([]))
                == String(localizable: .migrationPrepareStatePreparing)
        )
    }

    @Test func terminalAndInFlightStatesHaveTheirOwnCaptions() {
        #expect(MigrationPrepareBalanceSheet.stateCaption(for: .done) == String(localizable: .migrationPrepareStateDone))
        #expect(MigrationPrepareBalanceSheet.stateCaption(for: .readyToSend) == String(localizable: .migrationPrepareStateReady))
        #expect(MigrationPrepareBalanceSheet.stateCaption(for: .preparing) == String(localizable: .migrationPrepareStatePreparing))
        #expect(MigrationPrepareBalanceSheet.stateCaption(for: .scheduled) == String(localizable: .migrationPrepareStateScheduled))
    }

    // MARK: - Interim ladder (provisional data, permanent shape)

    @Test(arguments: [1, 2, 5]) func interimLadderProducesOneStepPerPreparation(count: Int) {
        #expect(MigrationPrepareBalanceRow.interimLadder(count: count).count == count)
    }

    /// Guards the sheet against a zero/negative count reaching it as an empty, headerless card.
    @Test(arguments: [0, -3]) func interimLadderNeverProducesAnEmptyList(count: Int) {
        #expect(MigrationPrepareBalanceRow.interimLadder(count: count).count == 1)
    }

    @Test func interimLadderLeadsWithAReadyStepThenAnInFlightOne() {
        let steps = MigrationPrepareBalanceRow.interimLadder(count: 4)
        #expect(steps[0].state == .readyToSend)
        #expect(steps[1].state == .preparing)
        #expect(steps[2].state == .waitsOn([2]))
        #expect(steps[3].state == .waitsOn([3]))
    }

    @Test func interimLadderIndexesFromZero() {
        let steps = MigrationPrepareBalanceRow.interimLadder(count: 3)
        #expect(steps.map(\.index) == [0, 1, 2])
        #expect(Set(steps.map(\.id)).count == 3)
    }

    // MARK: - The engine's real rows (field, 2026-08-03)

    private static func preparation(
        id: String,
        status: MigrationTransferRow.Status,
        minutesFromNow: Int? = nil,
        hoursFromNow: Int = 0
    ) -> MigrationTransferRow {
        MigrationTransferRow(
            id: id,
            index: 0,
            amount: nil,
            status: status,
            hoursFromNow: hoursFromNow,
            minutesFromNow: minutesFromNow,
            kind: .splitBalance
        )
    }

    /// A FINISHED step states no future. It used to state "Starts right away" — under a green
    /// checkmark, beside the word "Done" — because the field was a plain `Int` and 0 was the only
    /// number a done step could honestly supply.
    @Test func aDoneStepCarriesNoForwardTime() {
        let steps = MigrationPrepareBalanceRow.from(preparations: [
            Self.preparation(id: "0", status: .sent)
        ])

        #expect(steps.first?.state == .done)
        #expect(steps.first?.minutesFromNow == nil)
    }

    /// …and every unfinished step still does, so the sheet keeps the ladder the design draws.
    @Test func anUnfinishedStepKeepsItsForwardTime() {
        let steps = MigrationPrepareBalanceRow.from(preparations: [
            Self.preparation(id: "0", status: .active, minutesFromNow: 0),
            Self.preparation(id: "1", status: .pending, minutesFromNow: 41)
        ])

        #expect(steps[0].minutesFromNow == 0)
        #expect(steps[1].minutesFromNow == 41)
    }

    /// MINUTE precision, not `hoursFromNow * 60`. The coarse field truncates everything under an
    /// hour to 0, so a real ladder of sub-hour steps flattened into identical "Starts right away"
    /// lines — the design's 0/1/2/3-hour ladder rendered as four copies of one row.
    @Test func forwardTimeKeepsSubHourPrecision() {
        let steps = MigrationPrepareBalanceRow.from(preparations: [
            Self.preparation(id: "0", status: .pending, minutesFromNow: 41, hoursFromNow: 0),
            Self.preparation(id: "1", status: .pending, minutesFromNow: 42, hoursFromNow: 0)
        ])

        #expect(steps.map(\.minutesFromNow) == [41, 42], "41 and 42 minutes must not both read as 0")
    }

    // MARK: - Schedule-aware states (field, 2026-08-05)

    /// A pending step whose turn is still ahead is SCHEDULED — never "Ready to send". No user
    /// send action exists for a preparation (the app proves and delivers it), and the old
    /// mapping stamped every pending step ready regardless of a turn minutes-to-hours away.
    @Test func aFutureTurnReadsScheduledNotReadyToSend() {
        let steps = MigrationPrepareBalanceRow.from(preparations: [
            Self.preparation(id: "0", status: .active, minutesFromNow: 12)
        ])

        #expect(steps.first?.state == .scheduled)
        #expect(steps.first?.minutesFromNow == 12, "the time line carries the WHEN")
    }

    /// A due step is the app's work — "Preparing" — whether or not the sweep has picked it up
    /// yet. The field sheet this pins against: overdue rows stamped "Ready to send" with
    /// "Starts right away" as their only time line.
    @Test func aDueStepReadsPreparingEvenBeforeTheSweepPicksItUp() {
        let steps = MigrationPrepareBalanceRow.from(preparations: [
            Self.preparation(id: "0", status: .overdue, minutesFromNow: 0)
        ])

        #expect(steps.first?.state == .preparing)
    }

    /// On the chain's side: no forward time. A plain 0 there rendered "Starts right away"
    /// under the word "Sent" — the same lie the done-row fix already removed.
    @Test func aConfirmingStepCarriesNoForwardTime() {
        let steps = MigrationPrepareBalanceRow.from(preparations: [
            Self.preparation(id: "0", status: .confirming, minutesFromNow: 7)
        ])

        #expect(steps.first?.state == .sent)
        #expect(steps.first?.minutesFromNow == nil)
    }

    /// The fallback stays: a row with no minute-precise value still reports its coarse one rather
    /// than claiming "right away".
    @Test func forwardTimeFallsBackToHoursWhenThatIsAllThereIs() {
        let steps = MigrationPrepareBalanceRow.from(preparations: [
            Self.preparation(id: "0", status: .pending, minutesFromNow: nil, hoursFromNow: 2)
        ])

        #expect(steps.first?.minutesFromNow == 120)
    }
}
