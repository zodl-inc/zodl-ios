//
//  LiveMigrationEngineTests.swift
//  zodlTests
//
//  Covers `LiveMigrationEngine` (Dependencies/SDKSynchronizer/LiveMigrationEngine.swift) for
//  MOB-1469: the emit-rule table (state change / orchard 0->positive / positive->positive /
//  no-change), the `.inProgress` + overdue -> `.requiresAttention(.transferStalled)` stall
//  synthesis, mode-gated propose routing and note-split gating, the schedule persistence
//  round-trip (propose/sign -> pending rows, executeNext success -> first row `.sent`, re-init
//  rehydration, restart replacement), transfer-row derivation (status + hoursFromNow), summary
//  derivation, and the error policy (getter throw keeps last-known, proposal throw -> empty
//  schedule, executeNext throw -> `.networkError(retryable: true)`).
//
//  Every test drives the real engine against a `FakeGateway` (in-memory, call-recording) and
//  `MigrationScheduleStore.ephemeral()` — no process-global state, so no `.serialized`. The engine
//  is constructed directly with a plain `Gateway` value; no `@Dependency` overrides are needed.
//

import Testing
import Foundation
import os
@preconcurrency import Combine
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// MARK: - Fake gateway

/// Records every call the engine makes and lets each test script the SDK-side response (value or
/// thrown error) per method. Backed by an unfair lock since the engine calls it from `async`
/// contexts that may not all run on the same thread.
private final class FakeGateway: @unchecked Sendable {
    enum Call: Equatable {
        case currentAccountID
        case orchardBalance
        case state
        case progress
        case isNoteSplitNeeded
        case prepareNoteSplit
        case submitNoteSplit
        case proposeTransfers
        case proposeImmediateTransfers
        case signAndStore
        case isSyncRequiredBeforeNextTransfer
        case executeNext
        case hasOverdueTransfers
        case hasInvalidTransfers
        case restartCurrentStep
        case refreshStale
        case initializePostUpgrade
    }

    private struct State {
        var calls: [Call] = []
        var account: AccountUUID? = FakeGateway.defaultAccount
        var orchardBalance: Result<Zatoshi, Error> = .success(.zero)
        var state: Result<ZcashLightClientKit.MigrationState, Error> = .success(.notStarted)
        var progress: Result<ZcashLightClientKit.MigrationProgress?, Error> = .success(nil)
        var isNoteSplitNeeded: Result<Bool, Error> = .success(false)
        var prepareNoteSplit: Result<ZcashLightClientKit.NoteSplitProposal, Error> = .success(
            ZcashLightClientKit.NoteSplitProposal(outputNotes: [], fee: 0)
        )
        var submitNoteSplit: Result<ZcashLightClientKit.TransferResult, Error> = .success(.success(txid: "split-tx"))
        var proposeTransfers: Result<ZcashLightClientKit.MigrationSchedule, Error> = .success(
            ZcashLightClientKit.MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        )
        var proposeImmediateTransfers: Result<ZcashLightClientKit.MigrationSchedule, Error> = .success(
            ZcashLightClientKit.MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        )
        var signAndStore: Result<Void, Error> = .success(())
        var isSyncRequiredBeforeNextTransfer: Result<Bool, Error> = .success(false)
        var executeNext: Result<ZcashLightClientKit.TransferResult?, Error> = .success(nil)
        var hasOverdueTransfers: Result<Bool, Error> = .success(false)
        var hasInvalidTransfers: Result<Bool, Error> = .success(false)
        var restartCurrentStep: Result<ZcashLightClientKit.MigrationSchedule, Error> = .success(
            ZcashLightClientKit.MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        )
        var refreshStale: Result<UInt32, Error> = .success(0)
        var initializePostUpgrade: Result<Void, Error> = .success(())
    }

    private enum FakeError: Error { case scripted }

    static let defaultAccount = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var calls: [Call] { lock.withLock { $0.calls } }

    func callCount(_ call: Call) -> Int { calls.filter { $0 == call }.count }

    func setAccount(_ account: AccountUUID?) {
        lock.withLock { $0.account = account }
    }

    func setOrchardBalance(_ value: Zatoshi) {
        let result: Result<Zatoshi, Error> = .success(value)
        lock.withLock { $0.orchardBalance = result }
    }

    func setState(_ value: ZcashLightClientKit.MigrationState) {
        let result: Result<ZcashLightClientKit.MigrationState, Error> = .success(value)
        lock.withLock { $0.state = result }
    }

    func setStateThrows() {
        let result: Result<ZcashLightClientKit.MigrationState, Error> = .failure(FakeError.scripted)
        lock.withLock { $0.state = result }
    }

    func setProgress(_ value: ZcashLightClientKit.MigrationProgress?) {
        let result: Result<ZcashLightClientKit.MigrationProgress?, Error> = .success(value)
        lock.withLock { $0.progress = result }
    }

    func setIsNoteSplitNeeded(_ value: Bool) {
        let result: Result<Bool, Error> = .success(value)
        lock.withLock { $0.isNoteSplitNeeded = result }
    }

    func setProposeTransfersResult(_ value: ZcashLightClientKit.MigrationSchedule) {
        let result: Result<ZcashLightClientKit.MigrationSchedule, Error> = .success(value)
        lock.withLock { $0.proposeTransfers = result }
    }

    func setProposeTransfersThrows() {
        let result: Result<ZcashLightClientKit.MigrationSchedule, Error> = .failure(FakeError.scripted)
        lock.withLock { $0.proposeTransfers = result }
    }

    func setProposeImmediateTransfersResult(_ value: ZcashLightClientKit.MigrationSchedule) {
        let result: Result<ZcashLightClientKit.MigrationSchedule, Error> = .success(value)
        lock.withLock { $0.proposeImmediateTransfers = result }
    }

    func setSignAndStoreThrows() {
        let result: Result<Void, Error> = .failure(FakeError.scripted)
        lock.withLock { $0.signAndStore = result }
    }

    func setExecuteNextResult(_ value: ZcashLightClientKit.TransferResult?) {
        let result: Result<ZcashLightClientKit.TransferResult?, Error> = .success(value)
        lock.withLock { $0.executeNext = result }
    }

    func setExecuteNextThrows() {
        let result: Result<ZcashLightClientKit.TransferResult?, Error> = .failure(FakeError.scripted)
        lock.withLock { $0.executeNext = result }
    }

    func setHasOverdueTransfers(_ value: Bool) {
        let result: Result<Bool, Error> = .success(value)
        lock.withLock { $0.hasOverdueTransfers = result }
    }

    func setHasInvalidTransfers(_ value: Bool) {
        let result: Result<Bool, Error> = .success(value)
        lock.withLock { $0.hasInvalidTransfers = result }
    }

    func setRestartCurrentStepResult(_ value: ZcashLightClientKit.MigrationSchedule) {
        let result: Result<ZcashLightClientKit.MigrationSchedule, Error> = .success(value)
        lock.withLock { $0.restartCurrentStep = result }
    }

    func setRefreshStaleResult(_ value: UInt32) {
        let result: Result<UInt32, Error> = .success(value)
        lock.withLock { $0.refreshStale = result }
    }

    private func record(_ call: Call) {
        lock.withLock { $0.calls.append(call) }
    }

    var gateway: LiveMigrationEngine.Gateway {
        LiveMigrationEngine.Gateway(
            currentAccountID: { [weak self] in
                self?.record(.currentAccountID)
                return self?.lock.withLock { $0.account }
            },
            orchardBalance: { [weak self] _ in
                self?.record(.orchardBalance)
                let fallback: Result<Zatoshi, Error> = .success(.zero)
                return try (self?.lock.withLock { $0.orchardBalance } ?? fallback).get()
            },
            state: { [weak self] _ in
                self?.record(.state)
                let fallback: Result<ZcashLightClientKit.MigrationState, Error> = .success(.notStarted)
                return try (self?.lock.withLock { $0.state } ?? fallback).get()
            },
            progress: { [weak self] _ in
                self?.record(.progress)
                let fallback: Result<ZcashLightClientKit.MigrationProgress?, Error> = .success(nil)
                return try (self?.lock.withLock { $0.progress } ?? fallback).get()
            },
            isNoteSplitNeeded: { [weak self] _ in
                self?.record(.isNoteSplitNeeded)
                let fallback: Result<Bool, Error> = .success(false)
                return try (self?.lock.withLock { $0.isNoteSplitNeeded } ?? fallback).get()
            },
            prepareNoteSplit: { [weak self] _ in
                self?.record(.prepareNoteSplit)
                let fallback: Result<ZcashLightClientKit.NoteSplitProposal, Error> = .success(
                    ZcashLightClientKit.NoteSplitProposal(outputNotes: [], fee: 0)
                )
                return try (self?.lock.withLock { $0.prepareNoteSplit } ?? fallback).get()
            },
            submitNoteSplit: { [weak self] _, _, _ in
                self?.record(.submitNoteSplit)
                let fallback: Result<ZcashLightClientKit.TransferResult, Error> = .success(.success(txid: ""))
                return try (self?.lock.withLock { $0.submitNoteSplit } ?? fallback).get()
            },
            proposeTransfers: { [weak self] _ in
                self?.record(.proposeTransfers)
                let fallback: Result<ZcashLightClientKit.MigrationSchedule, Error> = .success(
                    ZcashLightClientKit.MigrationSchedule(transfers: [], estimatedDurationHours: 0)
                )
                return try (self?.lock.withLock { $0.proposeTransfers } ?? fallback).get()
            },
            proposeImmediateTransfers: { [weak self] _ in
                self?.record(.proposeImmediateTransfers)
                let fallback: Result<ZcashLightClientKit.MigrationSchedule, Error> = .success(
                    ZcashLightClientKit.MigrationSchedule(transfers: [], estimatedDurationHours: 0)
                )
                return try (self?.lock.withLock { $0.proposeImmediateTransfers } ?? fallback).get()
            },
            signAndStore: { [weak self] _, _ in
                self?.record(.signAndStore)
                let fallback: Result<Void, Error> = .success(())
                try (self?.lock.withLock { $0.signAndStore } ?? fallback).get()
            },
            isSyncRequiredBeforeNextTransfer: { [weak self] _ in
                self?.record(.isSyncRequiredBeforeNextTransfer)
                let fallback: Result<Bool, Error> = .success(false)
                return try (self?.lock.withLock { $0.isSyncRequiredBeforeNextTransfer } ?? fallback).get()
            },
            executeNext: { [weak self] _, _ in
                self?.record(.executeNext)
                let fallback: Result<ZcashLightClientKit.TransferResult?, Error> = .success(nil)
                return try (self?.lock.withLock { $0.executeNext } ?? fallback).get()
            },
            hasOverdueTransfers: { [weak self] _ in
                self?.record(.hasOverdueTransfers)
                let fallback: Result<Bool, Error> = .success(false)
                return try (self?.lock.withLock { $0.hasOverdueTransfers } ?? fallback).get()
            },
            hasInvalidTransfers: { [weak self] _ in
                self?.record(.hasInvalidTransfers)
                let fallback: Result<Bool, Error> = .success(false)
                return try (self?.lock.withLock { $0.hasInvalidTransfers } ?? fallback).get()
            },
            restartCurrentStep: { [weak self] _ in
                self?.record(.restartCurrentStep)
                let fallback: Result<ZcashLightClientKit.MigrationSchedule, Error> = .success(
                    ZcashLightClientKit.MigrationSchedule(transfers: [], estimatedDurationHours: 0)
                )
                return try (self?.lock.withLock { $0.restartCurrentStep } ?? fallback).get()
            },
            refreshStale: { [weak self] _ in
                self?.record(.refreshStale)
                let fallback: Result<UInt32, Error> = .success(0)
                return try (self?.lock.withLock { $0.refreshStale } ?? fallback).get()
            },
            initializePostUpgrade: { [weak self] _ in
                self?.record(.initializePostUpgrade)
                let fallback: Result<Void, Error> = .success(())
                try (self?.lock.withLock { $0.initializePostUpgrade } ?? fallback).get()
            }
        )
    }
}

// MARK: - Fixtures

private func sdkTransfer(id: String, amount: UInt64) -> ZcashLightClientKit.TransferProposal {
    ZcashLightClientKit.TransferProposal(
        id: id,
        amount: amount,
        anchorHeight: 100,
        nextExecutableAfterHeight: 100,
        expiryHeight: 200
    )
}

private func sdkSchedule(count: Int, amount: UInt64 = 1_000) -> ZcashLightClientKit.MigrationSchedule {
    ZcashLightClientKit.MigrationSchedule(
        transfers: (0..<count).map { sdkTransfer(id: "t\($0)", amount: amount) },
        estimatedDurationHours: UInt32(count * 6)
    )
}

// MARK: - Tests

@Suite struct LiveMigrationEngineTests {
    /// Builds an engine with its background refresh loop disabled (`startRefreshLoop: false`) so
    /// every test controls exactly when `refresh()` runs — this suite asserts on individual
    /// `refresh()` passes and would be flaky against a live 15s timer.
    private func makeEngine(
        gateway: FakeGateway = FakeGateway(),
        store: MigrationScheduleStore = .ephemeral()
    ) -> (engine: LiveMigrationEngine, gateway: FakeGateway) {
        let fake = gateway
        let engine = LiveMigrationEngine(store: store, gateway: fake.gateway, startRefreshLoop: false)
        return (engine, fake)
    }

    // MARK: Emit rules

    @Test func stateChangeEmits() async {
        let (engine, gateway) = makeEngine()
        var emitted: [MigrationState] = []
        let cancellable = engine.statePublisher().sink { emitted.append($0) }
        defer { cancellable.cancel() }

        gateway.setState(.readyToPropose)
        await engine.refresh()

        #expect(emitted == [.notStarted, .readyToPropose])
    }

    @Test func orchardZeroToPositiveEmitsWithUnchangedState() async {
        let (engine, gateway) = makeEngine()
        gateway.setOrchardBalance(.zero)
        await engine.refresh()

        var emitted: [MigrationState] = []
        let cancellable = engine.statePublisher().sink { emitted.append($0) }
        defer { cancellable.cancel() }

        gateway.setOrchardBalance(Zatoshi(500))
        await engine.refresh()

        // State itself never changed (`.notStarted` throughout), but the 0 -> positive threshold
        // crossing must still emit so the Home SmartBanner re-evaluates its migration offer.
        #expect(emitted == [.notStarted, .notStarted])
    }

    @Test func positiveToPositiveDoesNotEmit() async {
        let (engine, gateway) = makeEngine()
        gateway.setOrchardBalance(Zatoshi(500))
        await engine.refresh()

        var emitted: [MigrationState] = []
        let cancellable = engine.statePublisher().sink { emitted.append($0) }
        defer { cancellable.cancel() }

        gateway.setOrchardBalance(Zatoshi(999))
        await engine.refresh()

        // Only the initial subscription replay from `CurrentValueSubject` — no second emission for
        // a same-sign balance delta.
        #expect(emitted == [.notStarted])
    }

    @Test func noChangeDoesNotEmit() async {
        let (engine, _) = makeEngine()
        var emitted: [MigrationState] = []
        let cancellable = engine.statePublisher().sink { emitted.append($0) }
        defer { cancellable.cancel() }

        await engine.refresh()

        #expect(emitted == [.notStarted])
    }

    // MARK: Stall synthesis

    @Test func inProgressWithOverdueSynthesizesTransferStalled() async {
        let (engine, gateway) = makeEngine()
        let progress = ZcashLightClientKit.MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 5,
            remainingOrchard: 1_000,
            nextTransferReadyAtHeight: nil
        )
        gateway.setState(.inProgress(progress))
        gateway.setHasOverdueTransfers(true)

        await engine.refresh()

        #expect(
            engine.currentState() ==
            MigrationState.requiresAttention(AttentionReason.transferStalled(transferNumber: 3))
        )
    }

    @Test func inProgressWithoutOverdueStaysPlainInProgress() async {
        let (engine, gateway) = makeEngine()
        let progress = ZcashLightClientKit.MigrationProgress(
            completedTransfers: 1,
            totalTransfers: 4,
            remainingOrchard: 1_000,
            nextTransferReadyAtHeight: nil
        )
        gateway.setState(.inProgress(progress))
        gateway.setHasOverdueTransfers(false)

        await engine.refresh()

        #expect(engine.currentState() == MigrationState.inProgress(progress.app))
    }

    @Test func nonInProgressStateIsNeverSynthesized() async {
        let (engine, gateway) = makeEngine()
        gateway.setState(.requiresAttention(.transferExpired))
        gateway.setHasOverdueTransfers(true)

        await engine.refresh()

        // Overdue is irrelevant outside `.inProgress` — synthesis only rewrites `.inProgress`.
        #expect(engine.currentState() == MigrationState.requiresAttention(AttentionReason.transferExpired))
    }

    // MARK: Mode routing

    @Test func immediateModeProposeHitsImmediateGatewayClosure() async {
        let (engine, gateway) = makeEngine()
        engine.selectMode(.immediate)
        gateway.setProposeImmediateTransfersResult(sdkSchedule(count: 1, amount: 5_000))

        let schedule = await engine.propose()

        #expect(gateway.callCount(.proposeImmediateTransfers) == 1)
        #expect(gateway.callCount(.proposeTransfers) == 0)
        #expect(schedule.transfers.count == 1)
        #expect(schedule.transfers[0].amount == Zatoshi(5_000))
    }

    @Test func privateScheduledModeProposeHitsRegularGatewayClosure() async {
        let (engine, gateway) = makeEngine()
        engine.selectMode(.privateScheduled)
        gateway.setProposeTransfersResult(sdkSchedule(count: 3))

        let schedule = await engine.propose()

        #expect(gateway.callCount(.proposeTransfers) == 1)
        #expect(gateway.callCount(.proposeImmediateTransfers) == 0)
        #expect(schedule.transfers.count == 3)
    }

    @Test func defaultModeIsPrivateScheduledWithoutExplicitSelection() async {
        let (engine, gateway) = makeEngine()
        gateway.setProposeTransfersResult(sdkSchedule(count: 1))

        _ = await engine.propose()

        #expect(gateway.callCount(.proposeTransfers) == 1)
        #expect(gateway.callCount(.proposeImmediateTransfers) == 0)
    }

    // MARK: isNoteSplitNeeded mode gate

    @Test func noteSplitNeededIsFalseUnderImmediateModeEvenWhenSDKSaysTrue() async {
        let (engine, gateway) = makeEngine()
        gateway.setIsNoteSplitNeeded(true)
        engine.selectMode(.immediate)
        await engine.refresh()

        #expect(engine.noteSplitNeeded() == false)
    }

    @Test func noteSplitNeededReflectsSDKUnderPrivateScheduledMode() async {
        let (engine, gateway) = makeEngine()
        gateway.setIsNoteSplitNeeded(true)
        engine.selectMode(.privateScheduled)
        await engine.refresh()

        #expect(engine.noteSplitNeeded() == true)
    }

    // MARK: Schedule persistence round-trip

    @Test func signAndStoreCommitsRowsAsPending() async {
        let store = MigrationScheduleStore.ephemeral()
        let (engine, gateway) = makeEngine(store: store)
        gateway.setProposeTransfersResult(sdkSchedule(count: 2))
        let schedule = await engine.propose()

        await engine.signAndStore(schedule)

        #expect(gateway.callCount(.signAndStore) == 1)
        let persisted = store.load()
        #expect(persisted.transfers.count == 2)
        #expect(persisted.transfers.allSatisfy { $0.status == .pending })
    }

    @Test func executeNextSuccessAdvancesFirstRowToSent() async {
        let store = MigrationScheduleStore.ephemeral()
        let (engine, gateway) = makeEngine(store: store)
        gateway.setProposeTransfersResult(sdkSchedule(count: 2))
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        gateway.setExecuteNextResult(.success(txid: "tx-abc"))
        let result = await engine.executeNext(NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil))

        #expect(result == TransferResult.success(txId: "tx-abc"))
        let persisted = store.load()
        #expect(persisted.transfers[0].status == .sent(txId: "tx-abc"))
        #expect(persisted.transfers[1].status == .pending)
    }

    @Test func engineReinitFromSameEphemeralStoreRehydratesRows() async {
        let store = MigrationScheduleStore.ephemeral()
        let (firstEngine, firstGateway) = makeEngine(store: store)
        firstGateway.setProposeTransfersResult(sdkSchedule(count: 3, amount: 2_000))
        let schedule = await firstEngine.propose()
        await firstEngine.signAndStore(schedule)

        // A fresh engine instance over the SAME store (simulating relaunch) must render the
        // committed rows immediately, before its first `refresh()` completes.
        let (secondEngine, _) = makeEngine(gateway: FakeGateway(), store: store)

        let rows = secondEngine.transferRows()
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.amount == Zatoshi(2_000) })
    }

    @Test func restartReplacesPersistedSchedule() async {
        let store = MigrationScheduleStore.ephemeral()
        let (engine, gateway) = makeEngine(store: store)
        gateway.setProposeTransfersResult(sdkSchedule(count: 2))
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        gateway.setRestartCurrentStepResult(sdkSchedule(count: 1, amount: 9_999))
        let restarted = await engine.restart()

        #expect(restarted.transfers.count == 1)
        let persisted = store.load()
        #expect(persisted.transfers.count == 1)
        #expect(persisted.transfers[0].proposal.amount == Zatoshi(9_999))
        #expect(persisted.transfers[0].status == .pending)
    }

    // MARK: Row derivation

    @Test func rowDerivationCoversAllStatusesAndHoursMath() async {
        let (engine, gateway) = makeEngine()
        gateway.setProposeTransfersResult(sdkSchedule(count: 5, amount: 1_000))
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        let progress = ZcashLightClientKit.MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 5,
            remainingOrchard: 3_000,
            nextTransferReadyAtHeight: nil
        )
        gateway.setProgress(progress)
        gateway.setHasOverdueTransfers(false)
        gateway.setHasInvalidTransfers(false)
        await engine.refresh()

        let rows = engine.transferRows()
        #expect(rows.count == 5)
        // index 0, 1 < completed(2) -> sent
        #expect(rows[0].status == .sent)
        #expect(rows[1].status == .sent)
        // index 2 == completed -> active (neither overdue nor invalid)
        #expect(rows[2].status == .active)
        // index 3, 4 > completed -> pending, hoursFromNow = (index - completed) * 6
        #expect(rows[3].status == .pending)
        #expect(rows[3].hoursFromNow == 6)
        #expect(rows[4].status == .pending)
        #expect(rows[4].hoursFromNow == 12)
    }

    @Test func activeRowBecomesOverdueWhenCacheOverdue() async {
        let (engine, gateway) = makeEngine()
        gateway.setProposeTransfersResult(sdkSchedule(count: 2))
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        let progress = ZcashLightClientKit.MigrationProgress(
            completedTransfers: 0,
            totalTransfers: 2,
            remainingOrchard: 1_000,
            nextTransferReadyAtHeight: nil
        )
        gateway.setProgress(progress)
        gateway.setHasOverdueTransfers(true)
        gateway.setHasInvalidTransfers(false)
        await engine.refresh()

        #expect(engine.transferRows()[0].status == .overdue)
    }

    @Test func activeRowBecomesInvalidWhenCacheInvalid() async {
        let (engine, gateway) = makeEngine()
        gateway.setProposeTransfersResult(sdkSchedule(count: 2))
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        let progress = ZcashLightClientKit.MigrationProgress(
            completedTransfers: 0,
            totalTransfers: 2,
            remainingOrchard: 1_000,
            nextTransferReadyAtHeight: nil
        )
        gateway.setProgress(progress)
        gateway.setHasOverdueTransfers(true)
        gateway.setHasInvalidTransfers(true)
        await engine.refresh()

        // Invalid takes precedence over overdue for the active row.
        #expect(engine.transferRows()[0].status == .invalid)
    }

    @Test func noScheduleYieldsNoRows() async {
        let (engine, _) = makeEngine()
        #expect(engine.transferRows().isEmpty)
    }

    // MARK: Summary derivation

    @Test func summaryDerivesTransferredDustAndCounts() async {
        let (engine, gateway) = makeEngine()
        gateway.setProposeTransfersResult(sdkSchedule(count: 3, amount: 1_500))
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        let progress = ZcashLightClientKit.MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 3,
            remainingOrchard: 4_242,
            nextTransferReadyAtHeight: nil
        )
        gateway.setProgress(progress)
        gateway.setOrchardBalance(Zatoshi(4_242))
        await engine.refresh()

        let summary = engine.summary()
        #expect(summary.transferred == Zatoshi(3_000))
        #expect(summary.dust == Zatoshi(4_242))
        #expect(summary.transfersSent == 2)
        #expect(summary.transfersTotal == 3)
        #expect(summary.estimatedDurationHours == schedule.estimatedDurationHours)
    }

    // MARK: Error policy

    @Test func getterThrowKeepsLastKnownCacheValue() async {
        let (engine, gateway) = makeEngine()
        gateway.setState(.readyToPropose)
        await engine.refresh()
        #expect(engine.currentState() == MigrationState.readyToPropose)

        gateway.setStateThrows()
        await engine.refresh()

        // The failing field keeps its last-known value; other fields still refresh normally.
        #expect(engine.currentState() == MigrationState.readyToPropose)
    }

    @Test func proposalThrowReturnsEmptySchedule() async {
        let (engine, gateway) = makeEngine()
        gateway.setProposeTransfersThrows()

        let schedule = await engine.propose()

        #expect(schedule.transfers.isEmpty)
        #expect(schedule.estimatedDurationHours == 0)
    }

    @Test func executeNextThrowReturnsRetryableNetworkError() async {
        let (engine, gateway) = makeEngine()
        gateway.setExecuteNextThrows()

        let result = await engine.executeNext(NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil))

        #expect(result == TransferResult.networkError(retryable: true))
    }

    @Test func noActiveAccountSkipsExecuteNextWithRetryableNetworkError() async {
        let gateway = FakeGateway()
        gateway.setAccount(nil)
        let (engine, _) = makeEngine(gateway: gateway)

        let result = await engine.executeNext(NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil))

        #expect(result == TransferResult.networkError(retryable: true))
    }

    // MARK: Reschedule / recreate

    @Test func rescheduleStalledCallsRefreshStaleTransfers() async {
        let (engine, gateway) = makeEngine()
        gateway.setRefreshStaleResult(2)

        await engine.rescheduleStalled()

        #expect(gateway.callCount(.refreshStale) == 1)
    }

    @Test func recreateInvalidCallsRestartCurrentStep() async {
        let (engine, gateway) = makeEngine()
        gateway.setRestartCurrentStepResult(sdkSchedule(count: 1))

        await engine.recreateInvalid()

        #expect(gateway.callCount(.restartCurrentStep) == 1)
    }
}
