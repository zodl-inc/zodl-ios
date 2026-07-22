//
//  MigrationScheduledTests.swift
//  zodlTests
//
//  Covers the MigrationScheduled reducer
//  (Features/Migration/MigrationScheduled/MigrationScheduledStore.swift) for MOB-1463: the default
//  state and the `doneTapped` delegate contract. This is the terminal success screen for the
//  migration flow — no SDK calls, no navigation — chaining lands in MOB-1466. No shared/global
//  state -> no `.serialized`.
//
//  MOB-1458 (W-E): also covers `hasDust` — the "Dust balance remaining" card's visibility
//  condition (Figma 3480:7631). Hydration itself (what the coordinator fills these fields with at
//  push time) is covered by `MigrationCoordFlowTests.swift`, not here — this file stays scoped to
//  the reducer/state in isolation.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationScheduledTests {
    @MainActor @Test func defaultStateIsAllZero() async {
        let state = MigrationScheduled.State()

        #expect(state.totalAmount == Zatoshi.zero)
        #expect(state.sentCount == 0)
        #expect(state.totalCount == 0)
        #expect(state.durationHours == 0)
        #expect(state.dustAmount == Zatoshi.zero)
        #expect(state.hasDust == false)
    }

    // MARK: - MOB-1458 (W-E): hasDust — the dust card's visibility condition

    @MainActor @Test func hasDustIsFalseWhenDustAmountIsZero() async {
        let state = MigrationScheduled.State(dustAmount: Zatoshi.zero)

        #expect(state.hasDust == false)
    }

    @MainActor @Test func hasDustIsTrueWhenDustAmountIsPositive() async {
        let state = MigrationScheduled.State(dustAmount: Zatoshi(31_000))

        #expect(state.hasDust == true)
    }

    @MainActor @Test func doneTappedEmitsDelegateDone() async {
        let store = TestStore(initialState: MigrationScheduled.State()) {
            MigrationScheduled()
        }

        await store.send(.doneTapped)
        await store.receive(.delegate(.done))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationScheduled.State()) {
            MigrationScheduled()
        }

        await store.send(.delegate(.done))
    }
}
