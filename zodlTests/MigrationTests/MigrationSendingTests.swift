//
//  MigrationSendingTests.swift
//  zodlTests
//
//  Covers the MigrationSending reducer
//  (Features/Migration/MigrationSending/MigrationSendingStore.swift) for MOB-1463: the default
//  phase/state, the `closeTapped` / `viewTransactionTapped` delegate contracts, the failure sheet
//  dismissal (cancel/retry), and that `result` is a no-op for now — resubmitting the transfer is
//  MOB-1466's job. No shared/global state -> no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationSendingTests {
    @MainActor @Test func defaultStateIsSendingPhaseWithNoFailureSheet() async {
        let state = MigrationSending.State()

        #expect(state.phase == MigrationSending.State.Phase.sending)
        #expect(state.isFailurePresented == false)
        #expect(state.txId == "")
    }

    @MainActor @Test func closeTappedEmitsDelegateClosed() async {
        let store = TestStore(initialState: MigrationSending.State(phase: .success)) {
            MigrationSending()
        }

        await store.send(.closeTapped)
        await store.receive(.delegate(.closed))
    }

    @MainActor @Test func viewTransactionTappedEmitsDelegateViewTransaction() async {
        let store = TestStore(initialState: MigrationSending.State(phase: .success, txId: "e87f1234567890abcdef6f28b")) {
            MigrationSending()
        }

        await store.send(.viewTransactionTapped)
        await store.receive(.delegate(.viewTransaction))
    }

    @MainActor @Test func cancelTappedDismissesFailureSheet() async {
        let store = TestStore(initialState: MigrationSending.State(isFailurePresented: true)) {
            MigrationSending()
        }

        await store.send(.cancelTapped) {
            $0.isFailurePresented = false
        }
    }

    @MainActor @Test func retryTappedDismissesFailureSheet() async {
        let store = TestStore(initialState: MigrationSending.State(isFailurePresented: true)) {
            MigrationSending()
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
    }

    @MainActor @Test func resultNetworkErrorRetryableProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationSending.State()) {
            MigrationSending()
        }

        await store.send(.result(.networkError(retryable: true)))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationSending.State()) {
            MigrationSending()
        }

        await store.send(.delegate(.closed))
    }
}
