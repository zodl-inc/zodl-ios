//
//  MigrationNoteSplitTests.swift
//  zodlTests
//
//  Covers the MigrationNoteSplit reducer
//  (Features/Migration/MigrationNoteSplit/MigrationNoteSplitStore.swift) for MOB-1461/1466: the
//  default phase/state, the txid pasteboard copy, the failure sheet dismissal (cancel/retry), the
//  `continueTapped` delegate contract, and (MOB-1466) `onAppear` load/resume, `confirmTapped`
//  submission, the `migrationStateStream()` subscription driving `.splitConfirmed`, and retry
//  re-submission. The copy action writes the shared toast (`@Shared` in-memory state) ->
//  `.serialized` per the repo rule for suites mutating process-global state.
//

import Testing
import Foundation
@preconcurrency import Combine
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
        #expect(state.isFlowRoot == false)
    }

    @MainActor @Test func closeTappedWhenFlowRootEmitsDelegateContinued() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .splitting, isFlowRoot: true)) {
            MigrationNoteSplit()
        }

        await store.send(.closeTapped)
        await store.receive(.delegate(.continued))
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

    @MainActor @Test func continueTappedEmitsDelegateContinued() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .confirmed)) {
            MigrationNoteSplit()
        }

        await store.send(.continueTapped)
        await store.receive(.delegate(.continued))
    }

    @MainActor @Test func splitConfirmedSetsConfirmedPhase() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .splitting)) {
            MigrationNoteSplit()
        }

        await store.send(.splitConfirmed) {
            $0.phase = .confirmed
        }
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationNoteSplit.State()) {
            MigrationNoteSplit()
        }

        await store.send(.delegate(.continued))
    }

    // MARK: - onAppear: fresh load vs. resume

    @MainActor @Test func onAppearWhenNotPendingConfirmationPreparesNoteSplitAndPopulatesAmountFee() async {
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let store = TestStore(initialState: MigrationNoteSplit.State()) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.getMigrationState = { .readyToPropose }
            $0.sdkSynchronizer.migrationStateStream = { stateStream.eraseToAnyPublisher() }
            $0.sdkSynchronizer.prepareNoteSplit = {
                NoteSplitProposal(outputNotes: [Zatoshi(500_000_000), Zatoshi(500_000_000)], fee: Zatoshi(100_000))
            }
        }

        await store.send(.onAppear)
        await store.receive(\.noteSplitPrepared) {
            $0.proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000), Zatoshi(500_000_000)], fee: Zatoshi(100_000))
            $0.amount = Zatoshi(1_000_000_000)
            $0.fee = Zatoshi(100_000)
        }

        stateStream.send(completion: .finished)
        await store.finish()
    }

    @MainActor @Test func onAppearWhenSplitPendingConfirmationJumpsToSplittingPhaseWithoutPreparing() async {
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let prepareCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationNoteSplit.State()) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.getMigrationState = { .splitPendingConfirmation }
            $0.sdkSynchronizer.migrationStateStream = { stateStream.eraseToAnyPublisher() }
            $0.sdkSynchronizer.prepareNoteSplit = {
                prepareCalls.withValue { $0 += 1 }
                return NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero)
            }
        }

        await store.send(.onAppear) {
            $0.phase = .splitting
        }

        #expect(prepareCalls.value == 0)

        stateStream.send(completion: .finished)
        await store.finish()
    }

    @MainActor @Test func migrationStateStreamReadyToProposeAfterSplittingEmitsSplitConfirmed() async {
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let store = TestStore(initialState: MigrationNoteSplit.State()) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.getMigrationState = { .splitPendingConfirmation }
            $0.sdkSynchronizer.migrationStateStream = { stateStream.eraseToAnyPublisher() }
        }

        await store.send(.onAppear) {
            $0.phase = .splitting
        }

        stateStream.send(.readyToPropose)
        await store.receive(\.splitConfirmed) {
            $0.phase = .confirmed
        }

        stateStream.send(completion: .finished)
        await store.finish()
    }

    // MARK: - confirmTapped / submission

    @MainActor @Test func confirmTappedEntersSplittingPhaseAndSubmitsProposal() async {
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let submittedProposal = LockIsolated<NoteSplitProposal?>(nil)
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        var state = MigrationNoteSplit.State(phase: .explainer)
        state.proposal = proposal
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationStateStream = { stateStream.eraseToAnyPublisher() }
            $0.sdkSynchronizer.submitNoteSplit = { submitted in
                submittedProposal.setValue(submitted)
                return .success(txId: "e87f1234567890abcdef6f28b")
            }
        }

        await store.send(.confirmTapped) {
            $0.phase = .splitting
        }
        await store.receive(\.splitResult) {
            $0.txId = "e87f1234567890abcdef6f28b"
        }

        #expect(submittedProposal.value == proposal)

        stateStream.send(completion: .finished)
        await store.finish()
    }

    @MainActor @Test func splitResultSuccessStoresTxIdAndStaysInSplittingPhase() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .splitting)) {
            MigrationNoteSplit()
        }

        await store.send(.splitResult(.success(txId: "e87f1234567890abcdef6f28b"))) {
            $0.txId = "e87f1234567890abcdef6f28b"
        }

        #expect(store.state.phase == .splitting)
        #expect(store.state.isFailurePresented == false)
    }

    @MainActor @Test func splitResultNetworkErrorPresentsFailureSheet() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .splitting)) {
            MigrationNoteSplit()
        }

        await store.send(.splitResult(.networkError(retryable: true))) {
            $0.isFailurePresented = true
        }
    }

    @MainActor @Test func splitResultInvalidNotePresentsFailureSheet() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .splitting)) {
            MigrationNoteSplit()
        }

        await store.send(.splitResult(.invalidNote)) {
            $0.isFailurePresented = true
        }
    }

    @MainActor @Test func splitResultExpiredPresentsFailureSheet() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .splitting)) {
            MigrationNoteSplit()
        }

        await store.send(.splitResult(.expired)) {
            $0.isFailurePresented = true
        }
    }

    // MARK: - retryTapped: dismiss + re-submit

    @MainActor @Test func retryTappedDismissesFailureSheetAndResubmitsStoredProposal() async {
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let submitCalls = LockIsolated<Int>(0)
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        var state = MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true)
        state.proposal = proposal
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationStateStream = { stateStream.eraseToAnyPublisher() }
            $0.sdkSynchronizer.submitNoteSplit = { _ in
                submitCalls.withValue { $0 += 1 }
                return .success(txId: "retried-tx-id")
            }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.splitResult) {
            $0.txId = "retried-tx-id"
        }

        #expect(submitCalls.value == 1)

        stateStream.send(completion: .finished)
        await store.finish()
    }
}
