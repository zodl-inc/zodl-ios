//
//  MigrationRecoveryTests.swift
//  zodlTests
//
//  Covers the MigrationRecovery reducer
//  (Features/Migration/MigrationRecovery/MigrationRecoveryStore.swift) for MOB-1464/1466: the
//  default `.notesSpent` reason, the `continueTapped` delegate contract, and (MOB-1466) the
//  `isFlowRoot`-gated back control — `closeTapped` emits the new `.delegate(.close)` case when this
//  screen is the coordinator's re-entry root. No shared/global state -> no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

@Suite struct MigrationRecoveryTests {
    @MainActor @Test func defaultStateIsNotesSpentReasonWithDefaultTransferRange() async {
        let state = MigrationRecovery.State()

        #expect(state.reason == MigrationRecovery.State.Reason.notesSpent)
        #expect(state.firstTransfer == 3)
        #expect(state.lastTransfer == 5)
        #expect(state.isFlowRoot == false)
    }

    @MainActor @Test func expiredReasonIsPreservedInState() async {
        let state = MigrationRecovery.State(reason: .expired)

        #expect(state.reason == .expired)
    }

    @MainActor @Test func continueTappedEmitsDelegateRecreate() async {
        let store = TestStore(initialState: MigrationRecovery.State()) {
            MigrationRecovery()
        }

        await store.send(.continueTapped)
        await store.receive(.delegate(.recreate))
    }

    @MainActor @Test func continueTappedEmitsDelegateRecreateForExpiredReason() async {
        let store = TestStore(initialState: MigrationRecovery.State(reason: .expired)) {
            MigrationRecovery()
        }

        await store.send(.continueTapped)
        await store.receive(.delegate(.recreate))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationRecovery.State()) {
            MigrationRecovery()
        }

        await store.send(.delegate(.recreate))
    }

    @MainActor @Test func closeTappedEmitsDelegateClose() async {
        let store = TestStore(initialState: MigrationRecovery.State(isFlowRoot: true)) {
            MigrationRecovery()
        }

        await store.send(.closeTapped)
        await store.receive(.delegate(.close))
    }

    @MainActor @Test func delegateCloseActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationRecovery.State()) {
            MigrationRecovery()
        }

        await store.send(.delegate(.close))
    }
}
