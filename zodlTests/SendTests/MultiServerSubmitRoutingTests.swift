//
//  MultiServerSubmitRoutingTests.swift
//  secantTests
//
//  Created by Michal Fousek on 2026-06-12.
//

@preconcurrency import Combine
import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Drives TCA stores that touch the process-global `selectedWalletAccount` @Shared state,
// so the suite is serialized to avoid cross-test races on that storage.
@Suite(.serialized) @MainActor struct MultiServerSubmitSendRoutingTests {
    private var testWalletAccount: WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0, count: 16)),
                name: "Test",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private func makeStore(
        result: SDKSynchronizerClient.CreateProposedTransactionsResult,
        txIdExists: Bool = false
    ) -> TestStore<SendConfirmation.State, SendConfirmation.Action> {
        let initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )
        initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }
        store.exhaustivity = .off

        store.dependencies.audioServices = AudioServicesClient(systemSoundVibrate: { })
        store.dependencies.derivationTool = .liveValue
        store.dependencies.mainQueue = .immediate
        store.dependencies.mnemonic = .liveValue
        store.dependencies.walletStorage = .noOp
        store.dependencies.zcashSDKEnvironment = .testnet
        store.dependencies.sdkSynchronizer.createAndSubmitProposedTransactions = { _, _ in result }
        store.dependencies.sdkSynchronizer.txIdExists = { _ in txIdExists }

        return store
    }

    @Test func partialSubmissionRoutesToFailureSupportState() async {
        let firstTxId = Data([0xAA]).toHexStringTxId()
        let secondTxId = Data([0xBB]).toHexStringTxId()
        let statuses = ["accepted by endpoint 1", "all servers unreachable"]
        let store = makeStore(result: .partial(txIds: [firstTxId, secondTxId], statuses: statuses))

        await store.send(.sendTriggered)
        await store.finish()
        await store.skipReceivedActions(strict: false)

        #expect(store.state.result == .failure)
        #expect(store.state.txIdToExpand == firstTxId)
        #expect(store.state.partialFailureTxIds == [firstTxId, secondTxId])
        #expect(store.state.partialFailureStatuses == statuses)
        #expect(store.state.failedCode == -999)
        #expect(store.state.failedDescription == statuses.joined(separator: ", "))
        #expect(store.state.failureInfo == String(localizable: .sendPartialFailureInfo))
    }

    @Test func allServersRejectedRoutesToPendingWhenTxExistsLocally() async {
        let txId = Data([0xAA]).toHexStringTxId()
        let store = makeStore(result: .grpcFailure(txIds: [txId]), txIdExists: true)

        await store.send(.sendTriggered)
        await store.finish()
        await store.skipReceivedActions(strict: false)

        #expect(store.state.result == .pending)
        #expect(store.state.txIdToExpand == txId)
        #expect(store.state.pendingDescription == nil)
    }

    @Test func timeoutRoutesToPendingWithTimeoutCopy() async {
        let txId = Data([0xAA]).toHexStringTxId()
        let store = makeStore(
            result: .grpcFailure(txIds: [txId], reason: .timeout),
            txIdExists: true
        )

        await store.send(.sendTriggered)
        await store.finish()
        await store.skipReceivedActions(strict: false)

        #expect(store.state.result == .pending)
        #expect(store.state.txIdToExpand == txId)
        #expect(store.state.pendingDescription == String(localizable: .sendPendingTimeoutInfo))
        #expect(store.state.pendingInfo == String(localizable: .sendPendingTimeoutInfo))
    }

    @Test func onAppearResetsMultiServerSubmissionState() async {
        var initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )
        initialState.partialFailureTxIds = ["stale"]
        initialState.partialFailureStatuses = ["stale status"]
        initialState.pendingDescription = "stale description"

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }
        store.exhaustivity = .off

        store.dependencies.derivationTool = .liveValue
        store.dependencies.zcashSDKEnvironment = .testnet

        await store.send(.onAppear)
        await store.finish()
        await store.skipReceivedActions(strict: false)

        #expect(store.state.partialFailureTxIds.isEmpty)
        #expect(store.state.partialFailureStatuses.isEmpty)
        #expect(store.state.pendingDescription == nil)
    }
}

// Serialized for the same reason as above: the PCZT path runs through stores sharing
// process-global state and the audio/zcash environment dependencies.
@Suite(.serialized) @MainActor struct MultiServerSubmitPCZTRoutingTests {
    @Test func pcztSuccessBroadcastsAndResetsPCZTState() async {
        let txId = Data([0xAA]).toHexStringTxId()
        let pcztWithProofs = Pczt([0x10, 0x11])
        let pcztWithSigs = Pczt([0x20, 0x21])
        let createInputs = LockIsolated<[(Pczt, Pczt)]>([])

        var initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )
        initialState.pczt = Pczt([0x01])
        initialState.pcztWithProofs = pcztWithProofs
        initialState.pcztWithSigs = pcztWithSigs
        initialState.pcztToShare = Pczt([0x02])
        initialState.redactedPcztForSigner = Pczt([0x03])

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }
        store.exhaustivity = .off

        store.dependencies.audioServices = AudioServicesClient(systemSoundVibrate: { })
        store.dependencies.mainQueue = .immediate
        store.dependencies.zcashSDKEnvironment = .testnet
        store.dependencies.sdkSynchronizer.createAndSubmitTransactionFromPCZT = { proofs, sigs in
            createInputs.withValue { $0.append((proofs, sigs)) }
            return .success(txIds: [txId])
        }

        await store.send(.createTransactionFromPCZT)
        await store.finish()
        await store.skipReceivedActions(strict: false)

        createInputs.withValue { inputs in
            #expect(inputs.count == 1)
            #expect(inputs.first?.0 == pcztWithProofs)
            #expect(inputs.first?.1 == pcztWithSigs)
        }
        #expect(store.state.pczt == nil)
        #expect(store.state.pcztWithProofs == nil)
        #expect(store.state.pcztWithSigs == nil)
        #expect(store.state.pcztToShare == nil)
        #expect(store.state.proposal == nil)
        #expect(store.state.redactedPcztForSigner == nil)
        #expect(store.state.result == .success)
        #expect(store.state.txIdToExpand == txId)
    }

    @Test func pcztPartialRoutesToFailureWithSupportData() async {
        let firstTxId = Data([0xAA]).toHexStringTxId()
        let secondTxId = Data([0xBB]).toHexStringTxId()
        let statuses = ["accepted by endpoint 1", "rejected code: -25"]

        var initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )
        initialState.pcztWithProofs = Pczt([0x10, 0x11])
        initialState.pcztWithSigs = Pczt([0x20, 0x21])

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }
        store.exhaustivity = .off

        store.dependencies.audioServices = AudioServicesClient(systemSoundVibrate: { })
        store.dependencies.mainQueue = .immediate
        store.dependencies.zcashSDKEnvironment = .testnet
        store.dependencies.sdkSynchronizer.createAndSubmitTransactionFromPCZT = { _, _ in
            .partial(txIds: [firstTxId, secondTxId], statuses: statuses)
        }

        await store.send(.createTransactionFromPCZT)
        await store.finish()
        await store.skipReceivedActions(strict: false)

        #expect(store.state.result == .failure)
        #expect(store.state.txIdToExpand == firstTxId)
        #expect(store.state.partialFailureTxIds == [firstTxId, secondTxId])
        #expect(store.state.partialFailureStatuses == statuses)
        #expect(store.state.failedCode == -999)
        #expect(store.state.pcztWithProofs == nil)
        #expect(store.state.pcztWithSigs == nil)
    }

    @Test func pcztTimeoutRoutesToPendingWithTimeoutCopy() async {
        let txId = Data([0xAA]).toHexStringTxId()

        var initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )
        initialState.pcztWithProofs = Pczt([0x10, 0x11])
        initialState.pcztWithSigs = Pczt([0x20, 0x21])

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }
        store.exhaustivity = .off

        store.dependencies.audioServices = AudioServicesClient(systemSoundVibrate: { })
        store.dependencies.mainQueue = .immediate
        store.dependencies.zcashSDKEnvironment = .testnet
        store.dependencies.sdkSynchronizer.createAndSubmitTransactionFromPCZT = { _, _ in
            .grpcFailure(txIds: [txId], reason: .timeout)
        }
        store.dependencies.sdkSynchronizer.txIdExists = { _ in true }

        await store.send(.createTransactionFromPCZT)
        await store.finish()
        await store.skipReceivedActions(strict: false)

        #expect(store.state.result == .pending)
        #expect(store.state.txIdToExpand == txId)
        #expect(store.state.pendingDescription == String(localizable: .sendPendingTimeoutInfo))
    }
}
// MARK: - Swap & Pay routing

// Serialized: drives stores sharing the process-global `selectedWalletAccount` @Shared state.
// `SwapAndPayCoordFlow.State` is not Equatable, so these tests drive a plain `Store` and poll
// for the expected navigation state (same approach as VotingCoordFlowCoordinatorTests).
@Suite(.serialized) @MainActor struct MultiServerSubmitSwapRoutingTests {
    private var testWalletAccount: WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0, count: 16)),
                name: "Test",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private func makeStore(
        result: SDKSynchronizerClient.CreateProposedTransactionsResult,
        txIdExists: Bool = false
    ) -> StoreOf<SwapAndPayCoordFlow> {
        var initialState = SwapAndPayCoordFlow.State()
        initialState.swapAndPayState.address = "ztestaddr"
        initialState.swapAndPayState.proposal = .testOnlyFakeProposal(totalFee: 10_000)
        initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }

        return Store(initialState: initialState) {
            SwapAndPayCoordFlow()
        } withDependencies: {
            $0.derivationTool = .liveValue
            $0.mainQueue = .immediate
            $0.mnemonic = .liveValue
            $0.walletStorage = .noOp
            $0.zcashSDKEnvironment = .testnet
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.createAndSubmitProposedTransactions = { _, _ in result }
            $0.sdkSynchronizer.txIdExists = { _ in txIdExists }
        }
    }

    @Test func missingProposalRoutesToFailureNotPending() async {
        // Isolate shared account storage (see partialSubmissionRoutesToFailureSupportState). This test
        // reaches failure via the missing-proposal guard regardless of the account, but it still writes
        // `selectedWalletAccount`, so isolating keeps it from clobbering suites running in parallel.
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            // No proposal means nothing was created or submitted, so there is no transaction the
            // "pending" screen could be waiting for — this must land on the failure screen.
            var initialState = SwapAndPayCoordFlow.State()
            initialState.swapAndPayState.address = "ztestaddr"
            initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }

            let store = Store(initialState: initialState) {
                SwapAndPayCoordFlow()
            } withDependencies: {
                $0.mainQueue = .immediate
            }

            store.send(.swapRequested)
            await waitForStore {
                if case .sendResultFailure = store.state.path.last { return true }
                return false
            }
        }
    }

    @Test func partialSubmissionRoutesToFailureSupportState() async throws {
        // Pin the process-global `@Shared(.inMemory(.selectedWalletAccount))` storage to a fresh,
        // isolated `InMemoryStorage` for the duration of the test. Without this, a suite running in
        // parallel that mutates `selectedWalletAccount` can clobber it before `.swapRequested` reads
        // it; the reducer's `guard let ... state.selectedWalletAccount` then bails, navigation never
        // reaches `.sendResultFailure`, and `waitForStore` times out (a flaky CI failure). Mirrors the
        // isolation already used by `MultiServerSubmitFlexaRoutingTests`.
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let firstTxId = Data([0xAA]).toHexStringTxId()
            let secondTxId = Data([0xBB]).toHexStringTxId()
            let statuses = ["accepted by endpoint 1", "all servers unreachable"]
            let store = makeStore(result: .partial(txIds: [firstTxId, secondTxId], statuses: statuses))

            store.send(.swapRequested)
            await waitForStore {
                if case .sendResultFailure = store.state.path.last { return true }
                return false
            }

            guard case let .sendResultFailure(resultState) = store.state.path.last else {
                Issue.record("Expected Swap/Pay partial submission to route to failure")
                return
            }

            #expect(store.state.txIdToExpand == firstTxId)
            #expect(store.state.partialFailureTxIds == [firstTxId, secondTxId])
            #expect(store.state.partialFailureStatuses == statuses)
            #expect(store.state.failedCode == -999)
            #expect(store.state.failedDescription == statuses.joined(separator: ", "))
            #expect(resultState.txIdToExpand == firstTxId)
            #expect(resultState.partialFailureTxIds == [firstTxId, secondTxId])
            #expect(resultState.partialFailureStatuses == statuses)
            #expect(resultState.failedDescription == statuses.joined(separator: ", "))
        }
    }

    @Test func timeoutSubmissionRoutesToPendingWithTimeoutCopy() async throws {
        // Isolate shared account storage (see partialSubmissionRoutesToFailureSupportState).
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let txId = Data([0xAA]).toHexStringTxId()
            let store = makeStore(
                result: .grpcFailure(txIds: [txId], reason: .timeout),
                txIdExists: true
            )

            store.send(.swapRequested)
            await waitForStore {
                if case .sendResultPending = store.state.path.last { return true }
                return false
            }

            guard case let .sendResultPending(resultState) = store.state.path.last else {
                Issue.record("Expected Swap/Pay timeout submission to route to pending")
                return
            }

            #expect(store.state.txIdToExpand == txId)
            #expect(store.state.pendingDescription == String(localizable: .sendPendingTimeoutInfo))
            #expect(resultState.txIdToExpand == txId)
            #expect(resultState.pendingDescription == String(localizable: .sendPendingTimeoutInfo))
        }
    }

    @Test func keystonePendingKeepsPendingDescription() async throws {
        let txId = Data([0xAA]).toHexStringTxId()
        let timeoutDescription = String(localizable: .sendPendingTimeoutInfo)

        var sendConfirmationState = SendConfirmation.State.initial
        sendConfirmationState.address = "ztestaddr"
        sendConfirmationState.pendingDescription = timeoutDescription
        sendConfirmationState.result = .pending
        sendConfirmationState.txIdToExpand = txId

        var initialState = SwapAndPayCoordFlow.State()
        initialState.swapAndPayState.address = "ztestaddr"
        initialState.path.append(.confirmWithKeystone(sendConfirmationState))
        let keystonePathId = try #require(initialState.path.ids.last)

        let store = Store(initialState: initialState) {
            SwapAndPayCoordFlow()
        } withDependencies: {
            $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
            $0.mainQueue = .immediate
        }

        store.send(.path(.element(
            id: keystonePathId,
            action: .confirmWithKeystone(.updateResult(.pending))
        )))
        await waitForStore {
            if case .sendResultPending = store.state.path.last { return true }
            return false
        }

        guard case let .sendResultPending(resultState) = store.state.path.last else {
            Issue.record("Expected Swap/Pay Keystone pending result")
            return
        }

        #expect(store.state.txIdToExpand == txId)
        #expect(store.state.pendingDescription == timeoutDescription)
        #expect(resultState.txIdToExpand == txId)
        #expect(resultState.pendingDescription == timeoutDescription)
    }

    @Test func keystonePartialFailurePropagatesSupportData() async throws {
        let firstTxId = Data([0xAA]).toHexStringTxId()
        let secondTxId = Data([0xBB]).toHexStringTxId()
        let statuses = ["accepted by endpoint 1", "rejected code: -25"]

        var sendConfirmationState = SendConfirmation.State.initial
        sendConfirmationState.address = "ztestaddr"
        sendConfirmationState.failedCode = -999
        sendConfirmationState.failedDescription = statuses.joined(separator: ", ")
        sendConfirmationState.partialFailureTxIds = [firstTxId, secondTxId]
        sendConfirmationState.partialFailureStatuses = statuses
        sendConfirmationState.result = .failure
        sendConfirmationState.txIdToExpand = firstTxId

        var initialState = SwapAndPayCoordFlow.State()
        initialState.swapAndPayState.address = "ztestaddr"
        initialState.path.append(.confirmWithKeystone(sendConfirmationState))
        let keystonePathId = try #require(initialState.path.ids.last)

        let store = Store(initialState: initialState) {
            SwapAndPayCoordFlow()
        } withDependencies: {
            $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
            $0.mainQueue = .immediate
        }

        store.send(.path(.element(
            id: keystonePathId,
            action: .confirmWithKeystone(.updateResult(.failure))
        )))
        await waitForStore {
            if case .sendResultFailure = store.state.path.last { return true }
            return false
        }

        guard case let .sendResultFailure(resultState) = store.state.path.last else {
            Issue.record("Expected Swap/Pay Keystone partial failure to route to failure")
            return
        }

        #expect(store.state.partialFailureTxIds == [firstTxId, secondTxId])
        #expect(store.state.partialFailureStatuses == statuses)
        #expect(resultState.partialFailureTxIds == [firstTxId, secondTxId])
        #expect(resultState.partialFailureStatuses == statuses)
        #expect(resultState.failedCode == -999)
        #expect(resultState.txIdToExpand == firstTxId)
    }
}

// MARK: - Flexa routing

// Serialized: drives Root stores sharing the process-global `selectedWalletAccount` @Shared state.
// `Root.State` is not Equatable, so these tests drive a plain `Store` and poll the recorded
// Flexa handler calls.
@Suite(.serialized) @MainActor struct MultiServerSubmitFlexaRoutingTests {
    private enum FlexaTestConstants {
        static let commerceSessionId = "commerce-session-id"
        static let txId = "flexa-tx-id"
        static let recipientAddress = "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE"
    }

    private var testWalletAccount: WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0, count: 16)),
                name: "Test",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private func makeFlexaTransaction() -> FlexaTransaction {
        FlexaTransaction(
            amount: Zatoshi(100_000),
            address: FlexaTestConstants.recipientAddress,
            commerceSessionId: FlexaTestConstants.commerceSessionId
        )
    }

    /// Sends a Flexa transaction request through Root with the given submission result and
    /// waits until either `transactionSent` or a failure alert is recorded.
    private func runFlexa(
        result: SDKSynchronizerClient.CreateProposedTransactionsResult,
        txIdExists: Bool
    ) async -> (sent: [(String, String)], alerts: [(String, String)]) {
        let transactionSentCalls = LockIsolated<[(String, String)]>([])
        let alertCalls = LockIsolated<[(String, String)]>([])

        // Unlike the `TestStore` used by the sibling suites, a live `Store` shares the one
        // process-global `@Shared(.inMemory(.selectedWalletAccount))` storage. During a full
        // parallel run, other suites that mutate `selectedWalletAccount` clobber it mid-flight:
        // the Root reducer's `guard let account = state.selectedWalletAccount ...` then bails,
        // neither `transactionSent` nor `flexaAlert` fires, and `waitForStore` times out (a flaky
        // CI failure). Bind this test's `@Shared` state to a fresh, isolated in-memory store —
        // created inside the scope so `Root.State.initial`'s `@Shared` resolves against it — so
        // nothing running in parallel can interfere.
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let initialState = Root.State.initial
            initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                $0.derivationTool = .liveValue
                $0.flexaHandler = .noOp
                $0.flexaHandler.transactionSent = { commerceSessionId, txId in
                    transactionSentCalls.withValue { $0.append((commerceSessionId, txId)) }
                }
                $0.flexaHandler.flexaAlert = { title, message in
                    alertCalls.withValue { $0.append((title, message)) }
                }
                $0.localAuthentication = .mockAuthenticationSucceeded
                $0.mainQueue = .immediate
                $0.mnemonic = .mock
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.createAndSubmitProposedTransactions = { _, _ in result }
                $0.sdkSynchronizer.proposeTransfer = { _, _, _, _ in .testOnlyFakeProposal(totalFee: 0) }
                $0.sdkSynchronizer.txIdExists = { _ in txIdExists }
                $0.walletStorage = .noOp
                $0.zcashSDKEnvironment = .testnet
            }

            store.send(.flexaOnTransactionRequest(makeFlexaTransaction()))
            await waitForStore {
                transactionSentCalls.withValue { !$0.isEmpty } || alertCalls.withValue { !$0.isEmpty }
            }
        }

        return (transactionSentCalls.withValue { $0 }, alertCalls.withValue { $0 })
    }

    @Test func grpcFailureReportsSentWhenTxExistsLocally() async {
        // A transport-level failure is not a definitive failure: the SDK recorded a retry plan
        // before any network attempt and keeps rebroadcasting until the transaction mines or
        // expires, so it may still settle. Telling Flexa "failed" here would prompt the user
        // to pay again and risk a double payment.
        let outcome = await runFlexa(result: .grpcFailure(txIds: [FlexaTestConstants.txId]), txIdExists: true)

        #expect(outcome.sent.count == 1)
        #expect(outcome.sent.first?.1 == FlexaTestConstants.txId)
        #expect(outcome.alerts.isEmpty)
    }

    @Test func grpcFailureTimeoutReportsSentWhenTxExistsLocally() async {
        let outcome = await runFlexa(
            result: .grpcFailure(txIds: [FlexaTestConstants.txId], reason: .timeout),
            txIdExists: true
        )

        #expect(outcome.sent.count == 1)
        #expect(outcome.sent.first?.1 == FlexaTestConstants.txId)
        #expect(outcome.alerts.isEmpty)
    }

    @Test func grpcFailureFailsWhenTxIsMissingLocally() async {
        let outcome = await runFlexa(result: .grpcFailure(txIds: [FlexaTestConstants.txId]), txIdExists: false)

        #expect(outcome.sent.isEmpty)
        #expect(outcome.alerts.count == 1)
    }

    @Test func partialSubmissionFails() async {
        let outcome = await runFlexa(
            result: .partial(
                txIds: [FlexaTestConstants.txId],
                statuses: ["accepted by endpoint 1", "all servers unreachable"]
            ),
            txIdExists: true
        )

        #expect(outcome.sent.isEmpty)
        #expect(outcome.alerts.count == 1)
    }

    @Test func successReportsTransactionSent() async {
        let outcome = await runFlexa(result: .success(txIds: [FlexaTestConstants.txId]), txIdExists: true)

        #expect(outcome.sent.count == 1)
        #expect(outcome.sent.first?.0 == FlexaTestConstants.commerceSessionId)
        #expect(outcome.sent.first?.1 == FlexaTestConstants.txId)
        #expect(outcome.alerts.isEmpty)
    }

    @Test func successFailsWhenTxIsMissingLocally() async {
        let outcome = await runFlexa(result: .success(txIds: [FlexaTestConstants.txId]), txIdExists: false)

        #expect(outcome.sent.isEmpty)
        #expect(outcome.alerts.count == 1)
    }
}

@MainActor
private func waitForStore(
    // Generous deadline: these live stores deliver `.send`/`.run` effects through the cooperative
    // pool and `DispatchQueue.main`, both of which are heavily contended during a full parallel run
    // (the whole test target runs concurrently on a CPU-limited CI runner). The poll pumps the main
    // queue (via `Task.sleep`) and exits as soon as the condition holds, so a healthy test never
    // waits anywhere near this long — the deadline only guards against extreme scheduler starvation,
    // which is what made the 15s deadline flake on CI.
    timeoutNanoseconds: UInt64 = 60_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "Timed out waiting for store state", sourceLocation: sourceLocation)
}

// MARK: - Shielding routing

// Serialized: mutates the process-global `selectedWalletAccount` @Shared state.
@Suite(.serialized) struct MultiServerSubmitShieldingTests {
    @Test func partialSubmissionReportsFailure() async throws {
        let account = WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0, count: 16)),
                name: "Test",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount?
        $selectedWalletAccount.withLock { $0 = account }

        let states = LockIsolated<[ShieldingProcessorClient.State]>([])
        let cancellable = withDependencies {
            $0.derivationTool = .liveValue
            $0.mnemonic = .liveValue
            $0.walletStorage = .noOp
            $0.zcashSDKEnvironment = .testnet
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeShielding = { _, _, _, _ in .testOnlyFakeProposal(totalFee: 10_000) }
            $0.sdkSynchronizer.createAndSubmitProposedTransactions = { _, _ in
                .partial(
                    txIds: [Data([0xAA]).toHexStringTxId(), Data([0xBB]).toHexStringTxId()],
                    statuses: ["accepted by endpoint 1", "rejected by all servers"]
                )
            }
        } operation: {
            let client = ShieldingProcessorClient.live()
            let cancellable = client.observe().sink { state in
                states.withValue { $0.append(state) }
            }
            client.shieldFunds()
            return cancellable
        }

        var failedState: ShieldingProcessorClient.State?
        for _ in 0..<200 {
            let snapshot = states.withValue { $0 }
            if let terminal = snapshot.first(where: { state in
                if case .failed = state { return true }
                if case .succeeded = state { return true }
                if case .grpc = state { return true }
                return false
            }) {
                failedState = terminal
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        cancellable.cancel()

        guard case let .failed(error) = failedState else {
            Issue.record("Expected shielding partial submission to report failure, got \(String(describing: failedState))")
            return
        }
        #expect(String(describing: error).contains("partially failed"))
    }
}
