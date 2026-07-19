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
//  failure/`nil`, and retry re-running only the failed step. Also covers (MOB-1487/MOB-1494)
//  `isDustLane` defaulting to false and being settable via init — since MOB-1494 the flag only
//  selects the dust-sweep execution (the on-screen copy is identical in every lane). MOB-1496: both
//  lanes now hit the real per-account SDK surface — `executeNextPendingMigrationTransfer` needs a
//  concrete `AccountUUID`, and the dust lane additionally derives a real `UnifiedSpendingKey` (never
//  for a Keystone account, which has no PCZT-based dust-sweep lane yet). `.serialized`: several
//  cases drive the process-global `@Shared(.inMemory(.selectedWalletAccount))`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct MigrationSendingTests {
    private struct TestFailure: Error { }

    /// MOB-1496: every SDK call this store makes needs a concrete `AccountUUID` — this `init()` acts
    /// as a per-test setup hook (Swift Testing instantiates a fresh struct per `@Test`), seeding a
    /// selected software account by default; Keystone-specific tests override it locally. See
    /// `MigrationTransferPlanTests`' twin helper for the fuller rationale.
    init() {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = walletAccount(keystone: false, idByte: 0) }
    }

    private func walletAccount(keystone: Bool, idByte: UInt8) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: keystone ? "Keystone" : "Zodl",
                keySource: keystone ? String(localizable: .accountsKeystone).lowercased() : nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// MOB-1496: the dust lane's software path derives a real USK from the wallet's stored seed —
    /// see `MigrationTransferPlanTests`' twin helper for the rationale.
    private func withDependenciesUSKDerivable(_ values: inout DependencyValues) {
        values.derivationTool = .liveValue
        values.mnemonic = .mock
        values.walletStorage = .noOp
        values.zcashSDKEnvironment = .testnet
    }

    @MainActor @Test func defaultStateIsSendingPhaseWithNoFailureSheet() async {
        let state = MigrationSending.State()

        #expect(state.phase == MigrationSending.State.Phase.sending)
        #expect(state.isFailurePresented == false)
        #expect(state.txId == "")
        #expect(state.totalCount == 1)
        #expect(state.sentCount == 0)
        #expect(state.isDustLane == false)
    }

    @MainActor @Test func isDustLaneDefaultsFalseButCanBeSetTrueViaInit() async {
        let defaultState = MigrationSending.State()
        let dustLaneState = MigrationSending.State(isDustLane: true)

        #expect(defaultState.isDustLane == false)
        #expect(dustLaneState.isDustLane == true)
        // Unrelated defaults are untouched by the new trailing init parameter.
        #expect(dustLaneState.phase == MigrationSending.State.Phase.sending)
        #expect(dustLaneState.totalCount == 1)
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

    // MARK: - onAppear: no selected account -> nil result, same as any other failure

    @MainActor @Test func onAppearWithNoSelectedAccountReportsNilResultWithoutCallingSDK() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = nil }

        let executedCount = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executedCount.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-be-called")
            }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }

        #expect(executedCount.value == 0)
    }

    // MARK: - onAppear: single transfer (immediate/manual/plan-first)

    @MainActor @Test func onAppearWithSingleTransferSucceedsAndReachesSentPhase() async {
        let recordBroadcastCalls = LockIsolated<Int>(0)
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-0") }
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
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                let callIndex = executedCount.withValue { count -> Int in
                    count += 1
                    return count
                }
                return MigrationTransferResult.success(txId: "tx-\(callIndex)")
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
        let capturedOptions = LockIsolated<MigrationNetworkPrivacyOptions?>(nil)
        let options = MigrationNetworkPrivacyOptions(
            useTor: true,
            submissionEndpoint: LightWalletEndpoint(address: "example.com", port: 9067)
        )
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1, networkPrivacyOptions: options)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, passedOptions in
                capturedOptions.setValue(passedOptions)
                return MigrationTransferResult.success(txId: "tx-0")
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

    // MARK: - Dust lane (MOB-1487): "Migrate anyway" sweeps the remainder, not the scheduled path

    @MainActor @Test func onAppearWithDustLaneExecutesMigrateMigrationDustInsteadOfScheduledTransfer() async {
        let migrateDustCalls = LockIsolated<Int>(0)
        let executeNextCalls = LockIsolated<Int>(0)
        let recordBroadcastCalls = LockIsolated<Int>(0)
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let state = MigrationSending.State(totalCount: 1, isDustLane: true)
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrateMigrationDust = { _, _, _ in
                migrateDustCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "tx-dust")
            }
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executeNextCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "tx-wrong-lane")
            }
            $0.migrationManager.recordMigrationBroadcast = { recordBroadcastCalls.withValue { $0 += 1 } }
            $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-dust"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(migrateDustCalls.value == 1)
        #expect(executeNextCalls.value == 0)
        #expect(recordBroadcastCalls.value == 1)
        #expect(scheduleNextWindowCalls.value == 1)
    }

    @MainActor @Test func onAppearWithoutDustLaneExecutesScheduledTransferNotMigrateMigrationDust() async {
        let migrateDustCalls = LockIsolated<Int>(0)
        let executeNextCalls = LockIsolated<Int>(0)
        let state = MigrationSending.State(totalCount: 1, isDustLane: false)
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executeNextCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "tx-0")
            }
            $0.sdkSynchronizer.migrateMigrationDust = { _, _, _ in
                migrateDustCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "tx-dust")
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

        #expect(executeNextCalls.value == 1)
        #expect(migrateDustCalls.value == 0)
    }

    /// MOB-1496: the dust lane's USK derivation is never attempted for a Keystone account (no
    /// PCZT-based dust-sweep lane exists yet) — the guard reports a `nil` result (ordinary failure
    /// sheet) rather than deriving a USK for an account with no locally-held seed phrase.
    @MainActor @Test func onAppearWithDustLaneAndKeystoneAccountNeverDerivesUSKOrCallsMigrateMigrationDust() async {
        let deriveCalls = LockIsolated<Int>(0)
        let migrateDustCalls = LockIsolated<Int>(0)
        var state = MigrationSending.State(totalCount: 1, isDustLane: true)
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 7) }
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrateMigrationDust = { _, _, _ in
                migrateDustCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-be-called")
            }
            $0.derivationTool.deriveSpendingKey = { _, _, _ in
                deriveCalls.withValue { $0 += 1 }
                throw TestFailure()
            }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }

        #expect(deriveCalls.value == 0)
        #expect(migrateDustCalls.value == 0)
    }

    // MARK: - Failure / nil result: presents failure sheet, stops the sequence

    @MainActor @Test func onAppearWithFailureResultPresentsFailureSheetAndStopsSequence() async {
        let executedCount = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 3)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executedCount.withValue { $0 += 1 }
                return MigrationTransferResult.networkError(retryable: true)
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
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }
    }

    // MARK: - MOB-1496: broadcast-landed-but-record-failed is treated as success, not failure

    @MainActor @Test func onAppearWhenRecordFailsAfterBroadcastStillReachesSentPhase() async {
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                throw ZcashError.migrationRecordFailedAfterBroadcast(TestFailure())
            }
            $0.migrationManager.recordMigrationBroadcast = { }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = ""
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
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
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executedCount.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "retried-tx")
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
