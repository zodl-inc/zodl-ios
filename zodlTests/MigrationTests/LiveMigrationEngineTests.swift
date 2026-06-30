//
//  LiveMigrationEngineTests.swift
//  zodlTests
//
//  Exercises the live migration engine against a fake `LiveMigrationEngine.Gateway`: SDK->app type
//  mapping into the cache, error->fallback behaviour, the mutating ops, and app-side mode/ack
//  persistence. No real SDK or wallet is involved — the gateway is fully faked.
//

import Testing
import Foundation
import Combine
import os
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

private typealias AppMigrationState = zodl_internal.MigrationState
private typealias AppMigrationProgress = zodl_internal.MigrationProgress
private typealias AppNoteSplitProposal = zodl_internal.NoteSplitProposal
private typealias AppNetworkPrivacyOptions = zodl_internal.NetworkPrivacyOptions
private typealias AppTransferResult = zodl_internal.TransferResult
private typealias AppMigrationSchedule = zodl_internal.MigrationSchedule
private typealias AppTransferProposal = zodl_internal.TransferProposal

private struct GatewayBoom: Error {}

private let testAccount = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))

@Suite
struct LiveMigrationEngineTests {
    // MARK: - Helpers

    private func makeGateway(
        account: AccountUUID? = testAccount,
        orchardBalance: @escaping @Sendable (AccountUUID) async throws -> Zatoshi = { _ in Zatoshi(0) },
        state: @escaping @Sendable (AccountUUID) async throws -> ZcashLightClientKit.MigrationState = { _ in ZcashLightClientKit.MigrationState.notStarted },
        progress: @escaping @Sendable (AccountUUID) async throws -> ZcashLightClientKit.MigrationProgress? = { _ in nil },
        isNoteSplitNeeded: @escaping @Sendable (AccountUUID) async throws -> Bool = { _ in false },
        prepareNoteSplit: @escaping @Sendable (AccountUUID) async throws -> ZcashLightClientKit.NoteSplitProposal = { _ in ZcashLightClientKit.NoteSplitProposal(outputNotes: [], fee: 0) },
        submitNoteSplit: @escaping @Sendable (ZcashLightClientKit.NoteSplitProposal, ZcashLightClientKit.NetworkPrivacyOptions, AccountUUID) async throws -> ZcashLightClientKit.TransferResult = { _, _, _ in ZcashLightClientKit.TransferResult.success(txid: "split") },
        proposeTransfers: @escaping @Sendable (AccountUUID) async throws -> ZcashLightClientKit.MigrationSchedule = { _ in ZcashLightClientKit.MigrationSchedule(transfers: [], estimatedDurationHours: 0) },
        signAndStore: @escaping @Sendable (ZcashLightClientKit.MigrationSchedule, AccountUUID) async throws -> Void = { _, _ in },
        isSyncRequiredBeforeNextTransfer: @escaping @Sendable (AccountUUID) async throws -> Bool = { _ in false },
        executeNext: @escaping @Sendable (ZcashLightClientKit.NetworkPrivacyOptions, AccountUUID) async throws -> ZcashLightClientKit.TransferResult? = { _, _ in nil },
        hasOverdueTransfers: @escaping @Sendable (AccountUUID) async throws -> Bool = { _ in false },
        hasInvalidTransfers: @escaping @Sendable (AccountUUID) async throws -> Bool = { _ in false },
        restartCurrentStep: @escaping @Sendable (AccountUUID) async throws -> ZcashLightClientKit.MigrationSchedule = { _ in ZcashLightClientKit.MigrationSchedule(transfers: [], estimatedDurationHours: 0) },
        initializePostUpgrade: @escaping @Sendable (AccountUUID) async throws -> Void = { _ in }
    ) -> LiveMigrationEngine.Gateway {
        LiveMigrationEngine.Gateway(
            currentAccountID: { account },
            orchardBalance: orchardBalance,
            state: state,
            progress: progress,
            isNoteSplitNeeded: isNoteSplitNeeded,
            prepareNoteSplit: prepareNoteSplit,
            submitNoteSplit: submitNoteSplit,
            proposeTransfers: proposeTransfers,
            signAndStore: signAndStore,
            isSyncRequiredBeforeNextTransfer: isSyncRequiredBeforeNextTransfer,
            executeNext: executeNext,
            hasOverdueTransfers: hasOverdueTransfers,
            hasInvalidTransfers: hasInvalidTransfers,
            restartCurrentStep: restartCurrentStep,
            initializePostUpgrade: initializePostUpgrade
        )
    }

    private func makeEngine(
        store: MigrationStateStore = .ephemeral(),
        gateway: LiveMigrationEngine.Gateway
    ) -> LiveMigrationEngine {
        LiveMigrationEngine(store: store, gateway: gateway, refreshInterval: .seconds(3600), startRefreshLoop: false)
    }

    private func sdkProgress(_ completed: UInt32, _ total: UInt32, _ remaining: UInt64, _ next: UInt32?) -> ZcashLightClientKit.MigrationProgress {
        ZcashLightClientKit.MigrationProgress(
            completedTransfers: completed,
            totalTransfers: total,
            remainingOrchardZatoshi: remaining,
            nextTransferReadyAtHeight: next
        )
    }

    private func sdkTransfer(_ id: String, _ amount: UInt64) -> ZcashLightClientKit.TransferProposal {
        ZcashLightClientKit.TransferProposal(id: id, amountZatoshi: amount, anchorHeight: 0, nextExecutableAfterHeight: 0, expiryHeight: 0)
    }

    // MARK: - Refresh / cache

    @Test func refreshPopulatesStateFromGateway() async {
        let engine = makeEngine(gateway: makeGateway(state: { _ in ZcashLightClientKit.MigrationState.readyToPropose }))
        await engine.refresh()
        #expect(engine.currentState() == AppMigrationState.readyToPropose)
    }

    @Test func refreshEmitsStateOnPublisher() async {
        let engine = makeEngine(gateway: makeGateway(state: { _ in ZcashLightClientKit.MigrationState.readyToPropose }))
        let collected = OSAllocatedUnfairLock(initialState: [AppMigrationState]())
        let cancellable = engine.statePublisher().sink { state in
            collected.withLock { $0.append(state) }
        }
        await engine.refresh()
        cancellable.cancel()
        #expect(collected.withLock { $0 }.contains(AppMigrationState.readyToPropose))
    }

    @Test func syncGettersReflectCacheAfterRefresh() async {
        let engine = makeEngine(gateway: makeGateway(
            orchardBalance: { _ in Zatoshi(123) },
            isNoteSplitNeeded: { _ in true },
            isSyncRequiredBeforeNextTransfer: { _ in true },
            hasOverdueTransfers: { _ in true },
            hasInvalidTransfers: { _ in true }
        ))
        await engine.refresh()
        #expect(engine.noteSplitNeeded() == true)
        #expect(engine.syncRequiredBeforeNext() == true)
        #expect(engine.overdue() == true)
        #expect(engine.invalid() == true)
        #expect(engine.orchardBalance() == Zatoshi(123))
    }

    @Test func inProgressStateMapsProgress() async {
        let engine = makeEngine(gateway: makeGateway(
            state: { _ in ZcashLightClientKit.MigrationState.inProgress(self.sdkProgress(1, 2, 5, 10)) },
            progress: { _ in self.sdkProgress(1, 2, 5, 10) }
        ))
        await engine.refresh()
        let expectedProgress = AppMigrationProgress(completedTransfers: 1, totalTransfers: 2, remainingOrchard: Zatoshi(5), nextTransferReadyAtHeight: 10)
        #expect(engine.currentState() == AppMigrationState.inProgress(expectedProgress))
        #expect(engine.progress() == expectedProgress)
    }

    @Test func refreshKeepsLastStateButUpdatesOthersWhenStateThrows() async {
        let engine = makeEngine(gateway: makeGateway(
            orchardBalance: { _ in Zatoshi(99) },
            state: { _ in throw GatewayBoom() }
        ))
        await engine.refresh()
        #expect(engine.currentState() == AppMigrationState.notStarted)
        #expect(engine.orchardBalance() == Zatoshi(99))
    }

    @Test func refreshWithNoAccountKeepsDefaults() async {
        let engine = makeEngine(gateway: makeGateway(account: nil, state: { _ in ZcashLightClientKit.MigrationState.complete }))
        await engine.refresh()
        #expect(engine.currentState() == AppMigrationState.notStarted)
    }

    // MARK: - Mutating ops

    @Test func prepareSplitMapsProposal() async {
        let engine = makeEngine(gateway: makeGateway(
            prepareNoteSplit: { _ in ZcashLightClientKit.NoteSplitProposal(outputNotes: [5, 6], fee: 7) }
        ))
        let proposal = await engine.prepareSplit()
        #expect(proposal == AppNoteSplitProposal(outputNotes: [Zatoshi(5), Zatoshi(6)], fee: Zatoshi(7)))
    }

    @Test func submitSplitReturnsMappedResult() async {
        let engine = makeEngine(gateway: makeGateway(
            submitNoteSplit: { _, _, _ in ZcashLightClientKit.TransferResult.success(txid: "abc") }
        ))
        let result = await engine.submitSplit(AppNoteSplitProposal(outputNotes: [Zatoshi(1)], fee: Zatoshi(0)))
        #expect(result == AppTransferResult.success(txId: "abc"))
    }

    @Test func submitSplitNoAccountReturnsNetworkError() async {
        let engine = makeEngine(gateway: makeGateway(account: nil))
        let result = await engine.submitSplit(AppNoteSplitProposal(outputNotes: [], fee: Zatoshi(0)))
        #expect(result == AppTransferResult.networkError(retryable: true))
    }

    @Test func submitSplitGatewayThrowsReturnsNetworkError() async {
        let engine = makeEngine(gateway: makeGateway(
            submitNoteSplit: { _, _, _ in throw GatewayBoom() }
        ))
        let result = await engine.submitSplit(AppNoteSplitProposal(outputNotes: [], fee: Zatoshi(0)))
        #expect(result == AppTransferResult.networkError(retryable: true))
    }

    @Test func executeNextReturnsNilWhenNoTransferDue() async {
        let engine = makeEngine(gateway: makeGateway(executeNext: { _, _ in nil }))
        let result = await engine.executeNext(AppNetworkPrivacyOptions(useTor: false))
        #expect(result == nil)
    }

    @Test func executeNextMapsSuccess() async {
        let engine = makeEngine(gateway: makeGateway(
            executeNext: { _, _ in ZcashLightClientKit.TransferResult.success(txid: "xfer") }
        ))
        let result = await engine.executeNext(AppNetworkPrivacyOptions(useTor: false))
        #expect(result == AppTransferResult.success(txId: "xfer"))
    }

    @Test func executeNextGatewayThrowsReturnsNetworkError() async {
        let engine = makeEngine(gateway: makeGateway(
            executeNext: { _, _ in throw GatewayBoom() }
        ))
        let result = await engine.executeNext(AppNetworkPrivacyOptions(useTor: false))
        #expect(result == AppTransferResult.networkError(retryable: true))
    }

    @Test func proposeReturnsMappedSchedule() async {
        let engine = makeEngine(gateway: makeGateway(
            proposeTransfers: { _ in ZcashLightClientKit.MigrationSchedule(transfers: [self.sdkTransfer("t1", 500)], estimatedDurationHours: 6) }
        ))
        let schedule = await engine.propose()
        #expect(schedule.transfers.count == 1)
        #expect(schedule.transfers.first?.amount == Zatoshi(500))
        #expect(schedule.estimatedDurationHours == 6)
    }

    @Test func restartReturnsMappedSchedule() async {
        let engine = makeEngine(gateway: makeGateway(
            restartCurrentStep: { _ in ZcashLightClientKit.MigrationSchedule(transfers: [self.sdkTransfer("t1", 250)], estimatedDurationHours: 0) }
        ))
        let schedule = await engine.restart()
        #expect(schedule.transfers.first?.amount == Zatoshi(250))
    }

    // MARK: - Derived view models

    @Test func summaryDerivesFromScheduleAndProgress() async {
        let engine = makeEngine(gateway: makeGateway(
            orchardBalance: { _ in Zatoshi(11) },
            state: { _ in ZcashLightClientKit.MigrationState.inProgress(self.sdkProgress(1, 3, 11, 10)) },
            progress: { _ in self.sdkProgress(1, 3, 11, 10) },
            proposeTransfers: { _ in
                ZcashLightClientKit.MigrationSchedule(
                    transfers: [self.sdkTransfer("a", 100), self.sdkTransfer("b", 200), self.sdkTransfer("c", 300)],
                    estimatedDurationHours: 12
                )
            }
        ))
        _ = await engine.propose()
        await engine.refresh()
        let summary = engine.summary()
        #expect(summary.transfersTotal == 3)
        #expect(summary.transfersSent == 1)
        #expect(summary.transferred == Zatoshi(100))
        #expect(summary.dust == Zatoshi(11))
        #expect(summary.estimatedDurationHours == 12)
    }

    @Test func transferRowsDeriveStatusesFromProgress() async {
        let engine = makeEngine(gateway: makeGateway(
            state: { _ in ZcashLightClientKit.MigrationState.inProgress(self.sdkProgress(1, 3, 200, 10)) },
            progress: { _ in self.sdkProgress(1, 3, 200, 10) },
            proposeTransfers: { _ in
                ZcashLightClientKit.MigrationSchedule(
                    transfers: [self.sdkTransfer("a", 100), self.sdkTransfer("b", 200), self.sdkTransfer("c", 300)],
                    estimatedDurationHours: 12
                )
            }
        ))
        _ = await engine.propose()
        await engine.refresh()
        let rows = engine.transferRows()
        #expect(rows.count == 3)
        #expect(rows[0].status == .sent)
        #expect(rows[1].status == .active)
        #expect(rows[2].status == .pending)
    }

    // MARK: - App-side persistence

    @Test func selectModePersistsToStore() {
        let store = MigrationStateStore.ephemeral()
        let engine = makeEngine(store: store, gateway: makeGateway())
        engine.selectMode(.immediate)
        #expect(store.load().mode == .immediate)
    }

    @Test func acknowledgeCompletionPersistsAndReflects() {
        let store = MigrationStateStore.ephemeral()
        let engine = makeEngine(store: store, gateway: makeGateway())
        #expect(engine.isCompletionAcknowledged() == false)
        engine.acknowledgeCompletion()
        #expect(engine.isCompletionAcknowledged() == true)
        #expect(store.load().completionAcknowledged == true)
    }
}
