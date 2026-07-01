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
struct SDKSynchronizerClient: Sendable {
    enum CreateProposedTransactionsResult: Equatable, Sendable {
        enum GrpcFailureReason: Equatable, Sendable {
            case timeout
        }

        case failure(txIds: [String], code: Int, description: String)
        // No description payload on purpose: transport-level failures carry no server message,
        // and the UI derives its copy from `reason` (timeouts get dedicated localized copy).
        case grpcFailure(txIds: [String], reason: GrpcFailureReason? = nil)
        case partial(txIds: [String], statuses: [String])
        case success(txIds: [String])
    }
    
    let stateStream: @Sendable () -> AnyPublisher<SynchronizerState, Never>
    let eventStream: @Sendable () -> AnyPublisher<SynchronizerEvent, Never>
    let exchangeRateUSDStream: @Sendable () -> AnyPublisher<FiatCurrencyResult?, Never>
    let latestState: @Sendable () -> SynchronizerState
    
    let prepareWith: @Sendable ([UInt8], BlockHeight, WalletInitMode, String, String?) async throws -> Void
    let start: @Sendable (_ retry: Bool) async throws -> Void
    let stop: @Sendable () -> Void
    let isSyncing: @Sendable () -> Bool
    let isInitialized: @Sendable () -> Bool

    let importAccount: @Sendable (String, [UInt8]?, Zip32AccountIndex?, AccountPurpose, String, String?, BlockHeight?) async throws -> AccountUUID?
    var deleteAccount: @Sendable (AccountUUID) async throws -> Void

    let rescanFrom: @Sendable (BlockHeight) async throws -> Void

    let rewind: @Sendable (RewindPolicy) -> AnyPublisher<Void, Error>
    
    var getAllTransactions: @Sendable (AccountUUID?) async throws -> IdentifiedArrayOf<TransactionState>
    var transactionStatesFromZcashTransactions: @Sendable (AccountUUID?, [ZcashTransaction.Overview]) async throws -> IdentifiedArrayOf<TransactionState>
    var getMemos: @Sendable (Data) async throws -> [Memo]
    var txIdExists: @Sendable (String?) async throws -> Bool
    
    let getUnifiedAddress: @Sendable (_ account: AccountUUID) async throws -> UnifiedAddress?
    let getTransparentAddress: @Sendable (_ account: AccountUUID) async throws -> TransparentAddress?
    let getSaplingAddress: @Sendable (_ account: AccountUUID) async throws -> SaplingAddress?
    
    let getAccountsBalances: @Sendable () async throws -> [AccountUUID: AccountBalance]
    
    var wipe: @Sendable () -> AnyPublisher<Void, Error>?
    
    var switchToEndpoint: @Sendable (LightWalletEndpoint) async throws -> Void
    
    // Proposals
    var proposeTransfer: @Sendable (AccountUUID, Recipient, Zatoshi, Memo?) async throws -> Proposal
    /// Creates the proposal's transactions via the SDK `Broadcaster` and submits them to the
    /// endpoints chosen by the user's connection mode (Automatic -> all known servers,
    /// Manual -> the selected server). See `selectedSubmissionEndpoints`.
    var createAndSubmitProposedTransactions: @Sendable (Proposal, UnifiedSpendingKey) async throws -> CreateProposedTransactionsResult
    var proposeShielding: @Sendable (AccountUUID, Zatoshi, Memo, TransparentAddress?) async throws -> Proposal?
    
    var isSeedRelevantToAnyDerivedAccount: @Sendable ([UInt8]) async throws -> Bool
    
    var refreshExchangeRateUSD: @Sendable () -> Void
    
    var evaluateBestOf: @Sendable ([LightWalletEndpoint], Double, UInt64, Int, NetworkType) async -> [LightWalletEndpoint] = { _,_,_,_,_ in [] }

    var walletAccounts: @Sendable () async throws -> [WalletAccount] = { [] }
    
    var estimateBirthdayHeight: @Sendable (Date) -> BlockHeight = { _ in BlockHeight(0) }
    var estimateTimestamp: @Sendable (BlockHeight) -> TimeInterval? = { _ in nil }

    // PCZT
    var createPCZTFromProposal: @Sendable (AccountUUID, Proposal) async throws -> Pczt
    var addProofsToPCZT: @Sendable (Pczt) async throws -> Pczt
    /// PCZT variant of `createAndSubmitProposedTransactions`.
    var createAndSubmitTransactionFromPCZT: @Sendable (Pczt, Pczt) async throws -> CreateProposedTransactionsResult
    var urEncoderForPCZT: @Sendable (Pczt) -> UREncoder?
    var redactPCZTForSigner: @Sendable (Pczt) async throws  -> Pczt
    
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

    var getTreeState: @Sendable (_ height: UInt64) async throws -> Data

    // MARK: - Ironwood migration
    //
    // Thin wrappers over the SDK `Synchronizer` migration API. SDK migration types are fully qualified
    // (`ZcashLightClientKit.*`) because the app declares same-named Zatoshi-based mirrors; the
    // `LiveMigrationEngine` converts at its boundary (see MigrationTypeMapping.swift). The two
    // broadcasting calls (`migrationSubmitNoteSplit`, `migrationExecuteNextPendingTransfer`) acquire
    // the transaction guard inside their LiveKey closures — never at call sites, never nested.
    var migrationState: @Sendable (_ account: AccountUUID) async throws -> ZcashLightClientKit.MigrationState
    var migrationProgress: @Sendable (_ account: AccountUUID) async throws -> ZcashLightClientKit.MigrationProgress?
    var migrationIsNoteSplitNeeded: @Sendable (_ account: AccountUUID) async throws -> Bool
    var migrationPrepareNoteSplit: @Sendable (_ account: AccountUUID) async throws -> ZcashLightClientKit.NoteSplitProposal
    var migrationSubmitNoteSplit: @Sendable (
        _ proposal: ZcashLightClientKit.NoteSplitProposal,
        _ spendingKey: UnifiedSpendingKey,
        _ options: ZcashLightClientKit.NetworkPrivacyOptions,
        _ account: AccountUUID
    ) async throws -> ZcashLightClientKit.TransferResult
    var migrationProposeTransfers: @Sendable (_ account: AccountUUID) async throws -> ZcashLightClientKit.MigrationSchedule
    var migrationProposeImmediateTransfers: @Sendable (_ account: AccountUUID) async throws -> ZcashLightClientKit.MigrationSchedule
    var migrationSignAndStoreSchedule: @Sendable (
        _ schedule: ZcashLightClientKit.MigrationSchedule,
        _ spendingKey: UnifiedSpendingKey,
        _ account: AccountUUID
    ) async throws -> Void
    var migrationIsSyncRequiredBeforeNextTransfer: @Sendable (_ account: AccountUUID) async throws -> Bool
    var migrationExecuteNextPendingTransfer: @Sendable (
        _ options: ZcashLightClientKit.NetworkPrivacyOptions,
        _ account: AccountUUID
    ) async throws -> ZcashLightClientKit.TransferResult?
    var migrationHasOverdueTransfers: @Sendable (_ account: AccountUUID) async throws -> Bool
    var migrationHasInvalidTransfers: @Sendable (_ account: AccountUUID) async throws -> Bool
    var migrationRestartCurrentStep: @Sendable (_ account: AccountUUID) async throws -> ZcashLightClientKit.MigrationSchedule
    /// Re-anchors/re-proves/re-signs stale transfers (anchor too old to broadcast), returning how many
    /// were refreshed. Signs + persists but does NOT broadcast, so — like `migrationSignAndStoreSchedule`
    /// — its LiveKey closure does not acquire the transaction guard.
    var migrationRefreshStaleTransfers: @Sendable (
        _ spendingKey: UnifiedSpendingKey,
        _ account: AccountUUID
    ) async throws -> UInt32
    var migrationInitializePostUpgrade: @Sendable (_ account: AccountUUID) async throws -> Void
}

