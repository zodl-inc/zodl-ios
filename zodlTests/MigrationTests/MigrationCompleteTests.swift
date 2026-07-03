//
//  MigrationCompleteTests.swift
//  zodlTests
//
//  Covers the MigrationComplete reducer
//  (Features/Migration/MigrationComplete/MigrationCompleteStore.swift) for MOB-1464: the `hasDust`
//  derivation at zero/nonzero dust, and the `gotItTapped` delegate contract. Visual-only screen —
//  no SDK calls, no navigation. No shared/global state -> no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationCompleteTests {
    @MainActor @Test func defaultStateIsAllZeroWithNoDust() async {
        let state = MigrationComplete.State()

        #expect(state.totalTransferred == Zatoshi.zero)
        #expect(state.dust == Zatoshi.zero)
        #expect(state.transfersSent == 0)
        #expect(state.transfersTotal == 0)
        #expect(state.durationHours == 0)
        #expect(state.hasDust == false)
    }

    @MainActor @Test func hasDustIsFalseWhenDustIsZero() async {
        let state = MigrationComplete.State(dust: Zatoshi.zero)

        #expect(state.hasDust == false)
    }

    @MainActor @Test func hasDustIsTrueWhenDustIsNonzero() async {
        let state = MigrationComplete.State(dust: Zatoshi(31_000))

        #expect(state.hasDust)
    }

    @MainActor @Test func gotItTappedEmitsDelegateDone() async {
        let store = TestStore(initialState: MigrationComplete.State()) {
            MigrationComplete()
        }

        await store.send(.gotItTapped)
        await store.receive(.delegate(.done))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationComplete.State()) {
            MigrationComplete()
        }

        await store.send(.delegate(.done))
    }
}
