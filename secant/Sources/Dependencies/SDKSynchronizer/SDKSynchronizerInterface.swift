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
    
    let prepareWith: @Sendable ([UInt8], BlockHeight?, String, String?) async throws -> Void
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

    // MARK: - Migration (Orchard → Ironwood) — real SDK wiring (MOB-1496)
    //
    // Thin mirror of `any Synchronizer`'s migration surface. Every account-scoped member takes the
    // migrating account's `AccountUUID` and is `async throws`; `isMigrationSyncBlocked()` and the
    // two wallet-scope gate members are non-throwing (see `Synchronizer.swift`, ground truth).

    /// The account's current migration state — also the reconciliation hub.
    var getMigrationState: @Sendable (AccountUUID) async throws -> MigrationState
    /// Live migration progress, or `nil` when nothing is in progress.
    var getMigrationProgress: @Sendable (AccountUUID) async throws -> MigrationProgress?
    /// Whether the account's Orchard notes must be split before migration. THROWS before the
    /// wallet's first completed sync (no chain tip known yet).
    var isNoteSplitNeeded: @Sendable (AccountUUID) async throws -> Bool
    /// The optimal note split for the account's spendable Orchard balance.
    var prepareNoteSplit: @Sendable (AccountUUID) async throws -> NoteSplitProposal
    /// Signs, broadcasts, and records the account's note-split transaction (software path — needs
    /// the account's USK). Broadcast-bearing: guarded by the transaction guard in the LiveKey.
    var submitNoteSplit: @Sendable (
        AccountUUID, NoteSplitProposal, UnifiedSpendingKey, MigrationNetworkPrivacyOptions
    ) async throws -> MigrationTransferResult
    /// The full scheduled-migration schedule for the account's spendable Orchard balance.
    var proposeMigrationTransfers: @Sendable (AccountUUID, _ includeResidual: Bool) async throws -> MigrationSchedule
    /// The immediate (single-transaction) migration schedule for the account.
    var proposeImmediateMigration: @Sendable (AccountUUID) async throws -> MigrationSchedule
    /// The leftover Orchard balance a migration would not cross, when worth offering a choice
    /// about; `nil` when there is none. THROWS before the wallet's first completed sync.
    var residualAfterMigration: @Sendable (AccountUUID) async throws -> Zatoshi?
    /// Pre-signs and persists every transfer of `schedule` in the migration engine (needs the
    /// account's USK).
    var signAndStoreMigrationSchedule: @Sendable (AccountUUID, MigrationSchedule, UnifiedSpendingKey) async throws -> Void
    /// Whether a sync is required before the account's next migration transfer can proceed.
    var isSyncRequiredBeforeNextMigrationTransfer: @Sendable (AccountUUID) async throws -> Bool
    /// Broadcasts the next height-due migration transfer, or `nil` when nothing is currently due.
    /// Broadcast-bearing: guarded by the transaction guard in the LiveKey.
    var executeNextPendingMigrationTransfer: @Sendable (
        AccountUUID, MigrationNetworkPrivacyOptions
    ) async throws -> MigrationTransferResult?
    /// Wallet-scope: whether ordinary sync should currently be paused for a migration privacy gate.
    /// Non-throwing (degrades open on internal failure).
    var isMigrationSyncBlocked: @Sendable () async -> Bool = { false }
    /// Wallet-scope stream of `isMigrationSyncBlocked()`.
    var migrationSyncBlockedStream: @Sendable () -> AnyPublisher<Bool, Never> = { Empty().eraseToAnyPublisher() }
    /// The post-broadcast privacy buffer duration.
    var migrationPrivacySyncBufferDuration: @Sendable () -> TimeInterval = { 0 }
    /// Whether the account has a scheduled transfer past its send height but not yet broadcast.
    var hasOverdueMigrationTransfers: @Sendable (AccountUUID) async throws -> Bool
    /// Whether the account's migration is in an invalid state (spendable Orchard remains but no
    /// scheduled transfer covers it).
    var hasInvalidMigrationTransfers: @Sendable (AccountUUID) async throws -> Bool
    /// The account's next height-due pending transfer proposal, or `nil` when nothing is pending.
    var rescheduleOverdueMigrationTransfer: @Sendable (AccountUUID) async throws -> MigrationTransferProposal?
    /// Re-evaluates the account's remaining spendable Orchard balance and returns a fresh schedule.
    var restartCurrentMigrationStep: @Sendable (AccountUUID, _ includeResidual: Bool) async throws -> MigrationSchedule
    /// Re-proposes at a fresh anchor and re-signs the account's active run (needs the USK); returns
    /// the number refreshed.
    var refreshStaleMigrationTransfers: @Sendable (
        AccountUUID, UnifiedSpendingKey, _ includeResidual: Bool
    ) async throws -> UInt32
    /// [ext] MOB-1487 R3: would a regular send of `amount` draw on (unlocked) Orchard notes? Drives
    /// the send-form privacy disclaimer once Ironwood is active. Non-throwing: degrades to `false`
    /// (matches the pre-real-SDK stub's permissive default) on any read error.
    var sendRequiresOrchardFunds: @Sendable (AccountUUID, Zatoshi) async -> Bool = { _, _ in false }
    // Dust resolution — [ext] MOB-1487: `migrateMigrationDust` broadcasts the account's leftover
    // dust as one final transfer ("Migrate anyway") — deliberately NOT
    // `executeNextPendingMigrationTransfer`, which a background poll may call with no pending
    // transfers and must never sweep dust the user hasn't consented to move. `lockMigrationDust`/
    // `isMigrationDustLocked` are app persistence, not SDK calls — see `MigrationManagerClient`.
    var migrateMigrationDust: @Sendable (
        AccountUUID, UnifiedSpendingKey, MigrationNetworkPrivacyOptions
    ) async throws -> MigrationTransferResult?
    // Keystone (PCZT)
    var proposeNoteSplitPCZT: @Sendable (AccountUUID) async throws -> Data
    var submitSignedNoteSplit: @Sendable (AccountUUID, Data, MigrationNetworkPrivacyOptions) async throws -> MigrationTransferResult
    var proposeMigrationPCZTs: @Sendable (AccountUUID, MigrationSchedule) async throws -> [MigrationUnsignedTransferPczt]
    var storeSignedMigrationTransactions: @Sendable (AccountUUID, [MigrationSignedTransferPczt]) async throws -> Void
    // Batch UR encoding of N migration PCZTs into ONE animated-QR session — [ext]: JOINT SDK +
    // Keystone-team ask; device support unvalidated (feature-spec §14 risk).
    var urEncoderForMigrationPCZTBatch: @Sendable ([MigrationUnsignedTransferPczt]) -> UREncoder? = { _ in nil }
    // Batch parse of the scanned signed session back into N signed PCZTs' raw bytes, in scan order.
    var parseMigrationPCZTBatch: @Sendable (Data) -> [Data]? = { _ in nil }
}

