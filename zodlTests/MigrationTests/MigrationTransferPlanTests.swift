//
//  MigrationTransferPlanTests.swift
//  zodlTests
//
//  Covers the MigrationTransferPlan reducer
//  (Features/Migration/MigrationTransferPlan/MigrationTransferPlanStore.swift) for MOB-1463/1466:
//  the default `variant`, the `confirmTapped` delegate contract, and (MOB-1466) `onAppear` — a
//  fresh entry proposes transfers via `proposeMigrationTransfers()` and populates rows/duration,
//  while an injected schedule (recovery/reschedule variants) is left untouched (no re-propose) —
//  plus `confirmTapped` signing and storing the schedule via `signAndStoreMigrationSchedule`.
//  State carries the shared exchange rate but only reads it — nothing here mutates process-global
//  state -> no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationTransferPlanTests {
    @MainActor @Test func defaultStateIsScheduledVariantWithNoRows() async {
        let state = MigrationTransferPlan.State()

        #expect(state.variant == MigrationTransferPlan.State.Variant.scheduled)
        #expect(state.rows.isEmpty)
        #expect(state.totalDurationHours == 0)
        #expect(state.injectedSchedule == nil)
    }

    @MainActor @Test func recreatedVariantIsPreservedInState() async {
        let state = MigrationTransferPlan.State(variant: .recreated)

        #expect(state.variant == .recreated)
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationTransferPlan.State()) {
            MigrationTransferPlan()
        }

        await store.send(.delegate(.confirmed))
    }

    // MARK: - onAppear: fresh propose vs. injected schedule

    @MainActor @Test func onAppearWithNoInjectedScheduleProposesTransfersAndPopulatesRows() async {
        let schedule = MigrationSchedule(
            transfers: [
                TransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200),
                TransferProposal(id: "t1", amount: Zatoshi(300_000_000), anchorHeight: 100, nextExecutableAfterHeight: 150, expiryHeight: 250)
            ],
            estimatedDurationHours: 24
        )
        let store = TestStore(initialState: MigrationTransferPlan.State(variant: .scheduled)) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { schedule }
        }

        await store.send(.onAppear)
        await store.receive(\.transfersProposed) {
            $0.rows = [
                MigrationTransferRow(id: "t0", index: 0, amount: Zatoshi(500_000_000), status: .active, hoursFromNow: 0),
                MigrationTransferRow(id: "t1", index: 1, amount: Zatoshi(300_000_000), status: .pending, hoursFromNow: 0)
            ]
            $0.totalDurationHours = 24
            $0.schedule = schedule
        }
    }

    @MainActor @Test func onAppearWithInjectedScheduleDoesNotReProposeAndPopulatesRowsDirectly() async {
        let schedule = MigrationSchedule(
            transfers: [
                TransferProposal(id: "t0", amount: Zatoshi(200_000_000), anchorHeight: 50, nextExecutableAfterHeight: 50, expiryHeight: 150)
            ],
            estimatedDurationHours: 12
        )
        let proposeCalls = LockIsolated<Int>(0)
        var state = MigrationTransferPlan.State(variant: .recreated)
        state.injectedSchedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = {
                proposeCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0)
            }
        }

        await store.send(.onAppear) {
            $0.rows = [
                MigrationTransferRow(id: "t0", index: 0, amount: Zatoshi(200_000_000), status: .active, hoursFromNow: 0)
            ]
            $0.totalDurationHours = 12
            $0.schedule = schedule
        }

        #expect(proposeCalls.value == 0)
    }

    // MARK: - confirmTapped: sign + store, then delegate

    @MainActor @Test func confirmTappedSignsAndStoresScheduleThenEmitsDelegateConfirmed() async {
        let schedule = MigrationSchedule(
            transfers: [
                TransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        let signedSchedule = LockIsolated<MigrationSchedule?>(nil)
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { signedSchedule.setValue($0) }
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(signedSchedule.value == schedule)
    }

    @MainActor @Test func confirmTappedForManualVariantSignsAndStoresScheduleThenEmitsDelegateConfirmed() async {
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        var state = MigrationTransferPlan.State(variant: .manual)
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))
    }
}
