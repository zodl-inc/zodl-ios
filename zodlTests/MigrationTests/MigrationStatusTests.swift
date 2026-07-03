//
//  MigrationStatusTests.swift
//  zodlTests
//
//  Covers the MigrationStatus reducer (Features/Migration/MigrationStatus/MigrationStatusStore.swift)
//  for MOB-1464: the default `.progress` presentation, the `gotItTapped`/`sendNowTapped`/
//  `rescheduleTapped` delegate contracts, and the `remainingCount` derivation over a mixed row set.
//  Visual-only screen — no SDK calls, no navigation. No shared/global state -> no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationStatusTests {
    @MainActor @Test func defaultStateIsProgressPresentationWithNoRows() async {
        let state = MigrationStatus.State()

        #expect(state.presentation == MigrationStatus.State.Presentation.progress)
        #expect(state.rows.isEmpty)
        #expect(state.totalDurationHours == 0)
        #expect(state.stalledNumber == 0)
        #expect(state.stalledHoursAgo == 0)
        #expect(state.isRescheduling == false)
    }

    @MainActor @Test func gotItTappedEmitsDelegateDone() async {
        let store = TestStore(initialState: MigrationStatus.State()) {
            MigrationStatus()
        }

        await store.send(.gotItTapped)
        await store.receive(.delegate(.done))
    }

    @MainActor @Test func sendNowTappedEmitsDelegateSendNow() async {
        let store = TestStore(initialState: MigrationStatus.State(presentation: .resume)) {
            MigrationStatus()
        }

        await store.send(.sendNowTapped)
        await store.receive(.delegate(.sendNow))
    }

    @MainActor @Test func rescheduleTappedSetsIsReschedulingAndEmitsDelegateReschedule() async {
        let store = TestStore(initialState: MigrationStatus.State(presentation: .resume)) {
            MigrationStatus()
        }

        await store.send(.rescheduleTapped) {
            $0.isRescheduling = true
        }
        await store.receive(.delegate(.reschedule))
    }

    @MainActor @Test func remainingCountCountsAllRowsNotYetSent() async {
        var state = MigrationStatus.State()
        state.rows = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 18),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(2_000), status: .sent, hoursFromNow: 11),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(3_000), status: .overdue, hoursFromNow: 5),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(4_000), status: .pending, hoursFromNow: 1),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(5_000), status: .pending, hoursFromNow: 7)
        ]

        #expect(state.remainingCount == 3)
    }

    @MainActor @Test func remainingCountIsZeroWhenAllRowsSent() async {
        var state = MigrationStatus.State()
        state.rows = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 18),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(2_000), status: .sent, hoursFromNow: 11)
        ]

        #expect(state.remainingCount == 0)
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationStatus.State()) {
            MigrationStatus()
        }

        await store.send(.delegate(.done))
    }
}
