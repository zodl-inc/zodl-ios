//
//  SDKSynchronizerClient.swift
//  Zashi
//
//  Created by Lukáš Korba on 13.04.2022.
//

import Foundation
import Combine
import ComposableArchitecture
import ZcashLightClientKit
import Models
import URKit

extension DependencyValues {
    public var sdkSynchronizer: SDKSynchronizerClient {
        get { self[SDKSynchronizerClient.self] }
        set { self[SDKSynchronizerClient.self] = newValue }
    }
}

@DependencyClient
public struct SDKSynchronizerClient {
    public enum CreateProposedTransactionsResult: Equatable {
        case failure(txIds: [String], code: Int, description: String)
        case grpcFailure(txIds: [String])
        case partial(txIds: [String], statuses: [String])
        case success(txIds: [String])
    }
    
    public let stateStream: () -> AnyPublisher<SynchronizerState, Never>
    public let eventStream: () -> AnyPublisher<SynchronizerEvent, Never>
    public let exchangeRateUSDStream: () -> AnyPublisher<FiatCurrencyResult?, Never>
    public let latestState: () -> SynchronizerState
    
    public let prepareWith: ([UInt8], BlockHeight, WalletInitMode, String, String?) async throws -> Void
    public let start: (_ retry: Bool) async throws -> Void
    public let stop: () -> Void
    public let isSyncing: () -> Bool
    public let isInitialized: () -> Bool
    public let importAccount: (String, [UInt8]?, Zip32AccountIndex?, AccountPurpose, String, String?) async throws -> AccountUUID?
    
    public let rewind: (RewindPolicy) -> AnyPublisher<Void, Error>
    
    public var getAllTransactions: (AccountUUID?) async throws -> IdentifiedArrayOf<TransactionState>
    public var transactionStatesFromZcashTransactions: (AccountUUID?, [ZcashTransaction.Overview]) async throws -> IdentifiedArrayOf<TransactionState>
    public var getMemos: (Data) async throws -> [Memo]
    public var txIdExists: (String?) async throws -> Bool
    
    public let getUnifiedAddress: (_ account: AccountUUID) async throws -> UnifiedAddress?
    public let getTransparentAddress: (_ account: AccountUUID) async throws -> TransparentAddress?
    public let getSaplingAddress: (_ account: AccountUUID) async throws -> SaplingAddress?
    
    public let getAccountsBalances: () async throws -> [AccountUUID: AccountBalance]
    
    public var wipe: () -> AnyPublisher<Void, Error>?
    
    public var switchToEndpoint: (LightWalletEndpoint) async throws -> Void
    
    // Proposals
    public var proposeTransfer: (AccountUUID, Recipient, Zatoshi, Memo?) async throws -> Proposal
    public var createProposedTransactions: (Proposal, UnifiedSpendingKey) async throws -> CreateProposedTransactionsResult
    public var proposeShielding: (AccountUUID, Zatoshi, Memo, TransparentAddress?) async throws -> Proposal?
    
    public var isSeedRelevantToAnyDerivedAccount: ([UInt8]) async throws -> Bool
    
    public var refreshExchangeRateUSD: () -> Void
    
    public var evaluateBestOf: ([LightWalletEndpoint], Double, Double, UInt64, Int, NetworkType) async -> [LightWalletEndpoint] = { _,_,_,_,_,_ in [] }
    
    public var walletAccounts: () async throws -> [WalletAccount] = { [] }
    
    public var estimateBirthdayHeight: (Date) -> BlockHeight = { _ in BlockHeight(0) }
    
    // PCZT
    public var createPCZTFromProposal: (AccountUUID, Proposal) async throws -> Pczt
    public var addProofsToPCZT: (Pczt) async throws -> Pczt
    public var createTransactionFromPCZT: (Pczt, Pczt) async throws -> CreateProposedTransactionsResult
    public var urEncoderForPCZT: (Pczt) -> UREncoder?
    public var redactPCZTForSigner: (Pczt) async throws  -> Pczt
    
    // Search
    public var fetchTxidsWithMemoContaining: (String) async throws -> [Data]
    
    // UA with custom receivers
    public var getCustomUnifiedAddress: (AccountUUID, Set<ReceiverType>) async throws -> UnifiedAddress?
    
    // Tor
    public var torEnabled: (Bool) async throws -> Void
    public var exchangeRateEnabled: (Bool) async throws -> Void
    public var isTorSuccessfullyInitialized: () async -> Bool?
    public var httpRequestOverTor: (URLRequest) async throws -> (Data, HTTPURLResponse)

    public var debugDatabaseSql: (String) -> String = { _ in "" }
    
    public var getSingleUseTransparentAddress: (AccountUUID) async throws -> SingleUseTransparentAddress = { _ in
        SingleUseTransparentAddress(address: "", gapPosition: 0, gapLimit: 0)
    }
    public var checkSingleUseTransparentAddresses: (AccountUUID) async throws -> TransparentAddressCheckResult = { _ in .notFound }
    public var updateTransparentAddressTransactions: (String) async throws -> TransparentAddressCheckResult = { _ in .notFound }
    public var fetchUTXOsByAddress: (String, AccountUUID) async throws -> TransparentAddressCheckResult = { _, _ in .notFound }
    public var enhanceTransactionBy: (String) async throws -> Void

    public var checkWalletSpendability: @Sendable (String, SpendabilityProgressHandler?) async throws -> SpendabilityResult
    public var getPIRPendingSpends: @Sendable () async throws -> PIRPendingSpends
}

