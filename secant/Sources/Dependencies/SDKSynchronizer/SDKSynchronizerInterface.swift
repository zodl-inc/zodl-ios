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

@DependencyClient
struct SDKSynchronizerClient {
    enum CreateProposedTransactionsResult: Equatable {
        case failure(txIds: [String], code: Int, description: String)
        case grpcFailure(txIds: [String])
        case partial(txIds: [String], statuses: [String])
        case success(txIds: [String])
    }
    
    var stateStream: @Sendable () -> AnyPublisher<SynchronizerState, Never> = { Empty().eraseToAnyPublisher() }
    var eventStream: @Sendable () -> AnyPublisher<SynchronizerEvent, Never> = { Empty().eraseToAnyPublisher() }
    var exchangeRateUSDStream: @Sendable () -> AnyPublisher<FiatCurrencyResult?, Never> = { Empty().eraseToAnyPublisher() }
    var latestState: @Sendable () -> SynchronizerState = { .zero }

    var prepareWith: @Sendable ([UInt8], BlockHeight, WalletInitMode, String, String?) async throws -> Void
    var start: @Sendable (_ retry: Bool) async throws -> Void
    var stop: @Sendable () -> Void
    var isSyncing: @Sendable () -> Bool = { false }
    var isInitialized: @Sendable () -> Bool = { false }

    var importAccount: @Sendable (String, [UInt8]?, Zip32AccountIndex?, AccountPurpose, String, String?, BlockHeight?) async throws -> AccountUUID?
    var deleteAccount: @Sendable (AccountUUID) async throws -> Void

    var rescanFrom: @Sendable (BlockHeight) async throws -> Void

    var rewind: @Sendable (RewindPolicy) -> AnyPublisher<Void, Error> = { _ in Empty().eraseToAnyPublisher() }

    var getAllTransactions: @Sendable (AccountUUID?) async throws -> IdentifiedArrayOf<TransactionState>
    var transactionStatesFromZcashTransactions: @Sendable (AccountUUID?, [ZcashTransaction.Overview]) async throws -> IdentifiedArrayOf<TransactionState>
    var getMemos: @Sendable (Data) async throws -> [Memo]
    var txIdExists: @Sendable (String?) async throws -> Bool

    var getUnifiedAddress: @Sendable (_ account: AccountUUID) async throws -> UnifiedAddress?
    var getTransparentAddress: @Sendable (_ account: AccountUUID) async throws -> TransparentAddress?
    var getSaplingAddress: @Sendable (_ account: AccountUUID) async throws -> SaplingAddress?

    var getAccountsBalances: @Sendable () async throws -> [AccountUUID: AccountBalance]

    var wipe: @Sendable () -> AnyPublisher<Void, Error>?

    var switchToEndpoint: @Sendable (LightWalletEndpoint) async throws -> Void

    // Proposals
    var proposeTransfer: @Sendable (AccountUUID, Recipient, Zatoshi, Memo?) async throws -> Proposal
    var createProposedTransactions: @Sendable (Proposal, UnifiedSpendingKey) async throws -> CreateProposedTransactionsResult
    var proposeShielding: @Sendable (AccountUUID, Zatoshi, Memo, TransparentAddress?) async throws -> Proposal?

    var isSeedRelevantToAnyDerivedAccount: @Sendable ([UInt8]) async throws -> Bool

    var refreshExchangeRateUSD: @Sendable () -> Void

    var evaluateBestOf: @Sendable ([LightWalletEndpoint], Double, Double, UInt64, Int, NetworkType) async -> [LightWalletEndpoint] = { _,_,_,_,_,_ in [] }

    var walletAccounts: @Sendable () async throws -> [WalletAccount] = { [] }

    var estimateBirthdayHeight: @Sendable (Date) -> BlockHeight = { _ in BlockHeight(0) }
    var estimateTimestamp: @Sendable (BlockHeight) -> TimeInterval? = { _ in nil }

    // PCZT
    var createPCZTFromProposal: @Sendable (AccountUUID, Proposal) async throws -> Pczt
    var addProofsToPCZT: @Sendable (Pczt) async throws -> Pczt
    var createTransactionFromPCZT: @Sendable (Pczt, Pczt) async throws -> CreateProposedTransactionsResult
    var urEncoderForPCZT: @Sendable (Pczt) -> UREncoder?
    var redactPCZTForSigner: @Sendable (Pczt) async throws -> Pczt

    // Search
    var fetchTxidsWithMemoContaining: @Sendable (String) async throws -> [Data]

    // UA with custom receivers
    var getCustomUnifiedAddress: @Sendable (AccountUUID, Set<ReceiverType>) async throws -> UnifiedAddress?

    // Tor
    var torEnabled: @Sendable (Bool) async throws -> Void
    var exchangeRateEnabled: @Sendable (Bool) async throws -> Void
    var isTorSuccessfullyInitialized: @Sendable () async -> Bool?
    var httpRequestOverTor: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    var debugDatabaseSql: @Sendable (String) -> String = { _ in "" }

    var getSingleUseTransparentAddress: @Sendable (AccountUUID) async throws -> SingleUseTransparentAddress = { _ in
        SingleUseTransparentAddress(address: "", gapPosition: 0, gapLimit: 0)
    }
    var checkSingleUseTransparentAddresses: @Sendable (AccountUUID) async throws -> TransparentAddressCheckResult = { _ in .notFound }
    var updateTransparentAddressTransactions: @Sendable (String) async throws -> TransparentAddressCheckResult = { _ in .notFound }
    var fetchUTXOsByAddress: @Sendable (String, AccountUUID) async throws -> TransparentAddressCheckResult = { _, _ in .notFound }
    var enhanceTransactionBy: @Sendable (String) async throws -> Void
}

