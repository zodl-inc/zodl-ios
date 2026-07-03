//
//  MigrationNoteSplitTests.swift
//  zodlTests
//
//  Covers the MigrationNoteSplit reducer
//  (Features/Migration/MigrationNoteSplit/MigrationNoteSplitStore.swift) for MOB-1461: the default
//  phase/state, the txid pasteboard copy, the failure sheet dismissal (cancel/retry), and the
//  `continueTapped` delegate contract. Phase transitions and SDK calls are inert/declared-only —
//  wiring them up is MOB-1466's job. The copy action writes the shared toast (`@Shared` in-memory
//  state) -> `.serialized` per the repo rule for suites mutating process-global state.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct MigrationNoteSplitTests {
    @MainActor @Test func defaultStateIsExplainerWithNoFailureSheet() async {
        let state = MigrationNoteSplit.State()

        #expect(state.phase == MigrationNoteSplit.State.Phase.explainer)
        #expect(state.amount == Zatoshi.zero)
        #expect(state.fee == Zatoshi.zero)
        #expect(state.txId == "")
        #expect(state.isFailurePresented == false)
    }

    @MainActor @Test func copyTxIdTappedCopiesTxIdToPasteboard() async {
        let copied = LockIsolated<RedactableString?>(nil)
        let store = TestStore(
            initialState: MigrationNoteSplit.State(phase: .splitting, txId: "e87f1234567890abcdef6f28b")
        ) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.pasteboard.setString = { copied.setValue($0) }
        }
        store.exhaustivity = .off

        await store.send(.copyTxIdTapped)

        #expect(copied.value == "e87f1234567890abcdef6f28b".redacted)
        #expect(store.state.toast == .top(String(localizable: .generalCopiedToTheClipboard)))
    }

    @MainActor @Test func cancelTappedDismissesFailureSheet() async {
        let store = TestStore(
            initialState: MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true)
        ) {
            MigrationNoteSplit()
        }

        await store.send(.cancelTapped) {
            $0.isFailurePresented = false
        }
    }

    @MainActor @Test func retryTappedDismissesFailureSheet() async {
        let store = TestStore(
            initialState: MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true)
        ) {
            MigrationNoteSplit()
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
    }

    @MainActor @Test func continueTappedEmitsDelegateContinued() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .confirmed)) {
            MigrationNoteSplit()
        }

        await store.send(.continueTapped)
        await store.receive(.delegate(.continued))
    }

    @MainActor @Test func confirmTappedProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationNoteSplit.State()) {
            MigrationNoteSplit()
        }

        await store.send(.confirmTapped)
    }

    @MainActor @Test func splitConfirmedProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .splitting)) {
            MigrationNoteSplit()
        }

        await store.send(.splitConfirmed)
    }

    @MainActor @Test func splitResultInvalidNoteProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .splitting)) {
            MigrationNoteSplit()
        }

        await store.send(.splitResult(.invalidNote))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationNoteSplit.State()) {
            MigrationNoteSplit()
        }

        await store.send(.delegate(.continued))
    }
}
