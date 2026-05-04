//
//  SDKSynchronizerClient.swift
//  Zashi
//
//  Created by Lukáš Korba on 13.04.2022.
//

import Foundation
@preconcurrency import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import URKit

extension DependencyValues {
    var sdkSynchronizer: SDKSynchronizerClient {
        get { self[SDKSynchronizerClient.self] }
        set { self[SDKSynchronizerClient.self] = newValue }
    }
}

actor EndpointSwitchCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isSwitching = false
    private var waiters: [Waiter] = []

    func switchToEndpoint(
        _ endpoint: LightWalletEndpoint,
        previousEndpoint: LightWalletEndpoint? = nil,
        shouldProceed: @escaping @Sendable () async -> Bool = { true },
        switchToEndpoint: @escaping @Sendable (LightWalletEndpoint) async throws -> Void
    ) async throws {
        try await acquireSwitchSlot()
        var didSwitch = false
        defer { releaseSwitchSlot() }

        do {
            try Task.checkCancellation()
            guard await shouldProceed() else { return }
            try Task.checkCancellation()
            try await switchToEndpoint(endpoint)
            didSwitch = true
            try Task.checkCancellation()
        } catch {
            if didSwitch, let previousEndpoint {
                do {
                    try await switchToEndpoint(previousEndpoint)
                } catch {
                    LoggerProxy.error("[EndpointSwitch] Failed to restore endpoint after cancellation: \(error)")
                }
            }
            throw error
        }
    }

    private func acquireSwitchSlot() async throws {
        try Task.checkCancellation()

        guard isSwitching else {
            isSwitching = true
            return
        }

        let id = UUID()
        let acquired = await withTaskCancellationHandler(operation: {
            await self.enqueueWaiter(id: id)
        }, onCancel: {
            Task { await self.cancelWaiter(id: id) }
        })

        guard acquired else {
            throw CancellationError()
        }

        do {
            try Task.checkCancellation()
        } catch {
            releaseSwitchSlot()
            throw error
        }
    }

    private func enqueueWaiter(id: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }

        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: id, continuation: continuation))
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func releaseSwitchSlot() {
        guard !waiters.isEmpty else {
            isSwitching = false
            return
        }

        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: true)
    }
}

enum EndpointSwitching {
    static let coordinator = EndpointSwitchCoordinator()
}

@DependencyClient
struct SDKSynchronizerClient {
    enum CreateProposedTransactionsResult: Equatable {
        case failure(txIds: [String], code: Int, description: String)
        case grpcFailure(txIds: [String])
        case partial(txIds: [String], statuses: [String])
        case success(txIds: [String])
    }
    
    let stateStream: () -> AnyPublisher<SynchronizerState, Never>
    let eventStream: () -> AnyPublisher<SynchronizerEvent, Never>
    let exchangeRateUSDStream: () -> AnyPublisher<FiatCurrencyResult?, Never>
    let latestState: () -> SynchronizerState
    
    let prepareWith: ([UInt8], BlockHeight, WalletInitMode, String, String?) async throws -> Void
    let start: (_ retry: Bool) async throws -> Void
    let stop: () -> Void
    let isSyncing: () -> Bool
    let isInitialized: () -> Bool

    let importAccount: (String, [UInt8]?, Zip32AccountIndex?, AccountPurpose, String, String?, BlockHeight?) async throws -> AccountUUID?
    var deleteAccount: (AccountUUID) async throws -> Void

    let rescanFrom: (BlockHeight) async throws -> Void

    let rewind: (RewindPolicy) -> AnyPublisher<Void, Error>
    
    var getAllTransactions: (AccountUUID?) async throws -> IdentifiedArrayOf<TransactionState>
    var transactionStatesFromZcashTransactions: (AccountUUID?, [ZcashTransaction.Overview]) async throws -> IdentifiedArrayOf<TransactionState>
    var getMemos: (Data) async throws -> [Memo]
    var txIdExists: (String?) async throws -> Bool
    
    let getUnifiedAddress: (_ account: AccountUUID) async throws -> UnifiedAddress?
    let getTransparentAddress: (_ account: AccountUUID) async throws -> TransparentAddress?
    let getSaplingAddress: (_ account: AccountUUID) async throws -> SaplingAddress?
    
    let getAccountsBalances: () async throws -> [AccountUUID: AccountBalance]
    
    var wipe: () -> AnyPublisher<Void, Error>?
    
    var switchToEndpoint: (LightWalletEndpoint) async throws -> Void
    
    // Proposals
    var proposeTransfer: (AccountUUID, Recipient, Zatoshi, Memo?) async throws -> Proposal
    var createProposedTransactions: (Proposal, UnifiedSpendingKey) async throws -> CreateProposedTransactionsResult
    var broadcasterCreateProposedTransactions: (Proposal, UnifiedSpendingKey) async throws -> [ZcashTransaction.Overview]
    var createAndSubmitProposedTransactions: (Proposal, UnifiedSpendingKey) async throws -> CreateProposedTransactionsResult
    var proposeShielding: (AccountUUID, Zatoshi, Memo, TransparentAddress?) async throws -> Proposal?

    // Multi-server submission
    var broadcasterSubmit: (Data, LightWalletEndpoint) async throws -> Void
    
    var isSeedRelevantToAnyDerivedAccount: ([UInt8]) async throws -> Bool
    
    var refreshExchangeRateUSD: () -> Void
    
    var evaluateBestOf: ([LightWalletEndpoint], Double, Double, UInt64, Int, NetworkType) async -> [LightWalletEndpoint] = { _,_,_,_,_,_ in [] }
    
    var walletAccounts: () async throws -> [WalletAccount] = { [] }
    
    var estimateBirthdayHeight: (Date) -> BlockHeight = { _ in BlockHeight(0) }
    var estimateTimestamp: (BlockHeight) -> TimeInterval? = { _ in nil }

    // PCZT
    var createPCZTFromProposal: (AccountUUID, Proposal) async throws -> Pczt
    var addProofsToPCZT: (Pczt) async throws -> Pczt
    var createTransactionFromPCZT: (Pczt, Pczt) async throws -> CreateProposedTransactionsResult
    var broadcasterCreateTransactionFromPCZT: (Pczt, Pczt) async throws -> [ZcashTransaction.Overview]
    var createAndSubmitTransactionFromPCZT: (Pczt, Pczt) async throws -> CreateProposedTransactionsResult
    var urEncoderForPCZT: (Pczt) -> UREncoder?
    var redactPCZTForSigner: (Pczt) async throws  -> Pczt
    
    // Search
    var fetchTxidsWithMemoContaining: (String) async throws -> [Data]
    
    // UA with custom receivers
    var getCustomUnifiedAddress: (AccountUUID, Set<ReceiverType>) async throws -> UnifiedAddress?
    
    // Tor
    var torEnabled: (Bool) async throws -> Void
    var exchangeRateEnabled: (Bool) async throws -> Void
    var isTorSuccessfullyInitialized: () async -> Bool?
    var httpRequestOverTor: (URLRequest) async throws -> (Data, HTTPURLResponse)
    
    var debugDatabaseSql: (String) -> String = { _ in "" }
    
    var getSingleUseTransparentAddress: (AccountUUID) async throws -> SingleUseTransparentAddress = { _ in
        SingleUseTransparentAddress(address: "", gapPosition: 0, gapLimit: 0)
    }
    var checkSingleUseTransparentAddresses: (AccountUUID) async throws -> TransparentAddressCheckResult = { _ in .notFound }
    var updateTransparentAddressTransactions: (String) async throws -> TransparentAddressCheckResult = { _ in .notFound }
    var fetchUTXOsByAddress: (String, AccountUUID) async throws -> TransparentAddressCheckResult = { _, _ in .notFound }
    var enhanceTransactionBy: (String) async throws -> Void

    var getTreeState: @Sendable (_ height: UInt64) async throws -> Data
}
