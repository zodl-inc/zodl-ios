//
//  MigrationSendingTests.swift
//  zodlTests
//
//  Covers the MigrationSending reducer
//  (Features/Migration/MigrationSending/MigrationSendingStore.swift) for MOB-1463/1466: the default
//  phase/state, the `closeTapped` / `viewTransactionTapped` delegate contracts, the failure sheet
//  dismissal (cancel/retry), and (MOB-1466) `onAppear` executing `totalCount` transfers strictly in
//  sequence via `executeNextPendingMigrationTransfer`, recording a broadcast +
//  scheduling the next background window after each success, presenting the failure sheet on
//  failure/`nil`, and retry re-running only the failed step. No shared/global state ->
//  no `.serialized`.
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
        #expect(state.totalCount == 1)
        #expect(state.sentCount == 0)
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

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationSending.State()) {
            MigrationSending()
        }

        await store.send(.delegate(.closed))
    }

    // MARK: - onAppear: single transfer (immediate/manual/plan-first)

    @MainActor @Test func onAppearWithSingleTransferSucceedsAndReachesSentPhase() async {
        let recordBroadcastCalls = LockIsolated<Int>(0)
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _ in .success(txId: "tx-0") }
            $0.migrationManager.recordMigrationBroadcast = { recordBroadcastCalls.withValue { $0 += 1 } }
            $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-0"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(recordBroadcastCalls.value == 1)
        #expect(scheduleNextWindowCalls.value == 1)
    }

    // MARK: - onAppear: sequential N transfers (send-now)

    @MainActor @Test func onAppearWithMultipleTransfersExecutesStrictlyInSequence() async {
        let executedCount = LockIsolated<Int>(0)
        let recordBroadcastCalls = LockIsolated<Int>(0)
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 3)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _ in
                let callIndex = executedCount.withValue { count -> Int in
                    count += 1
                    return count
                }
                return .success(txId: "tx-\(callIndex)")
            }
            $0.migrationManager.recordMigrationBroadcast = { recordBroadcastCalls.withValue { $0 += 1 } }
            $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-1"
        }
        await store.receive(\.transferResult) {
            $0.sentCount = 2
            $0.txId = "tx-2"
        }
        await store.receive(\.transferResult) {
            $0.sentCount = 3
            $0.txId = "tx-3"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(executedCount.value == 3)
        #expect(recordBroadcastCalls.value == 3)
        #expect(scheduleNextWindowCalls.value == 3)
    }

    @MainActor @Test func onAppearPassesInjectedNetworkPrivacyOptionsToExecute() async {
        let capturedOptions = LockIsolated<NetworkPrivacyOptions?>(nil)
        let options = NetworkPrivacyOptions(useTor: true, submissionEndpoint: "https://example.com:9067")
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1, networkPrivacyOptions: options)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { passedOptions in
                capturedOptions.setValue(passedOptions)
                return .success(txId: "tx-0")
            }
            $0.migrationManager.recordMigrationBroadcast = { }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-0"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(capturedOptions.value == options)
    }

    // MARK: - Failure / nil result: presents failure sheet, stops the sequence

    @MainActor @Test func onAppearWithFailureResultPresentsFailureSheetAndStopsSequence() async {
        let executedCount = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 3)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _ in
                executedCount.withValue { $0 += 1 }
                return .networkError(retryable: true)
            }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }

        #expect(executedCount.value == 1)
        #expect(store.state.sentCount == 0)
    }

    @MainActor @Test func onAppearWithNilResultPresentsFailureSheet() async {
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _ in nil }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }
    }

    // MARK: - retryTapped: re-runs only the failed step

    @MainActor @Test func retryTappedDismissesFailureSheetAndReRunsFailedStep() async {
        let executedCount = LockIsolated<Int>(0)
        let state = MigrationSending.State(isFailurePresented: true, totalCount: 2, sentCount: 1)
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _ in
                executedCount.withValue { $0 += 1 }
                return .success(txId: "retried-tx")
            }
            $0.migrationManager.recordMigrationBroadcast = { }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.transferResult) {
            $0.sentCount = 2
            $0.txId = "retried-tx"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(executedCount.value == 1)
    }
}
