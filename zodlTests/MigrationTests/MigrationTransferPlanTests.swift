//
//  MigrationTransferPlanTests.swift
//  zodlTests
//
//  Covers the MigrationTransferPlan reducer
//  (Features/Migration/MigrationTransferPlan/MigrationTransferPlanStore.swift) for MOB-1463: the
//  default `variant`, and the `confirmTapped` delegate contract. Signing and storing the schedule
//  is inert for now — wiring it up is MOB-1466's job. No shared/global state -> no `.serialized`.
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
    }

    @MainActor @Test func confirmTappedEmitsDelegateConfirmed() async {
        let store = TestStore(initialState: MigrationTransferPlan.State()) {
            MigrationTransferPlan()
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.confirmed))
    }

    @MainActor @Test func confirmTappedEmitsDelegateConfirmedForManualVariant() async {
        let store = TestStore(initialState: MigrationTransferPlan.State(variant: .manual)) {
            MigrationTransferPlan()
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.confirmed))
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
}
