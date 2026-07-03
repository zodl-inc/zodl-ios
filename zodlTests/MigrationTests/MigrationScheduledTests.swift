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
