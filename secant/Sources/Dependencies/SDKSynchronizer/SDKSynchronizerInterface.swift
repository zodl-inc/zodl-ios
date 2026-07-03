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
    
    let prepareWith: @Sendable ([UInt8], BlockHeight, WalletInitMode, String, String?) async throws -> Initializer.InitializationResult
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

    // MARK: - Migration (Orchard → Ironwood) — stubs until the SDK API exists (MOB-1455)
    //
    // Swift mirror of `interface OrchardMigrationSdk` (`MigrationSdk.kt`). Names are qualified
    // to fit this client's flat namespace (e.g. `stateStream` is already taken by
    // `SynchronizerState`). Markers: `[draft]` = Kotlin draft 1:1, `[ext]` = proposed SDK
    // extension not present in the Kotlin draft.

    // State — Kotlin: getMigrationState / (Flow suggestion) / getMigrationProgress
    var getMigrationState: @Sendable () -> MigrationState = { .notStarted }                                   // [draft]
    var migrationStateStream: @Sendable () -> AnyPublisher<MigrationState, Never> = { Empty().eraseToAnyPublisher() }  // [ext]
    var getMigrationProgress: @Sendable () -> MigrationProgress? = { nil }                                    // [draft]
    // Note splitting
    var isNoteSplitNeeded: @Sendable () -> Bool = { false }                                                   // [draft]
    var prepareNoteSplit: @Sendable () async -> NoteSplitProposal = { NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero) }  // [draft]
    var submitNoteSplit: @Sendable (NoteSplitProposal) async -> TransferResult = { _ in TransferResult.success(txId: "") }     // [draft]
    // Proposal
    var selectMigrationMode: @Sendable (MigrationMode) -> Void = { _ in }                                     // [ext]
    var proposeMigrationTransfers: @Sendable () async -> MigrationSchedule = {  // [draft]
        MigrationSchedule(transfers: [], estimatedDurationHours: 0)
    }
    var signAndStoreMigrationSchedule: @Sendable (MigrationSchedule) async -> Void = { _ in }                 // [draft]
    // Background execution — Kotlin: isSyncRequiredBeforeNextTransfer / executeNextPendingTransfer
    var isSyncRequiredBeforeNextMigrationTransfer: @Sendable () -> Bool = { false }                           // [draft]
    var executeNextPendingMigrationTransfer: @Sendable (NetworkPrivacyOptions) async -> TransferResult? = { _ in nil }  // [draft]
    // On-launch reconciliation — Kotlin: hasOverdueTransfers / hasInvalidTransfers
    var hasOverdueMigrationTransfers: @Sendable () -> Bool = { false }                                        // [draft]
    var hasInvalidMigrationTransfers: @Sendable () -> Bool = { false }                                        // [draft]
    // Recovery
    var restartCurrentMigrationStep: @Sendable () async -> MigrationSchedule = {  // [draft]
        MigrationSchedule(transfers: [], estimatedDurationHours: 0)
    }
    var rescheduleStalledMigrationTransfer: @Sendable () async -> Void = { }                                  // [ext]
    var recreateInvalidMigrationTransfer: @Sendable () async -> Void = { }                                    // [ext]
    // Progress UI
    var migrationSummary: @Sendable () -> MigrationSummary = { MigrationSummary.zero }                        // [ext]
    var migrationTransfers: @Sendable () -> [MigrationTransferRow] = { [] }                                   // [ext]
    // Keystone (PCZT)
    var proposeNoteSplitPCZT: @Sendable () async -> Pczt = { Pczt() }                                         // [ext]
    var proposeMigrationPCZTs: @Sendable (MigrationSchedule) async -> [Pczt] = { _ in [] }                    // [ext]
    var storeSignedMigrationTransactions: @Sendable ([Pczt]) async -> Void = { _ in }                         // [ext]
    // Keystone note-split broadcast — [ext]: symmetric with submitNoteSplit; SDK must treat this
    // broadcast as the migration note split (state -> splitPendingConfirmation).
    var submitSignedNoteSplit: @Sendable (Pczt) async -> TransferResult = { _ in TransferResult.success(txId: "") }
    // Batch UR encoding of N migration PCZTs into ONE animated-QR session — [ext]: JOINT SDK +
    // Keystone-team ask; device support unvalidated (feature-spec §14 risk). Stub: nil (screen dormant).
    var urEncoderForMigrationPCZTBatch: @Sendable ([Pczt]) -> UREncoder? = { _ in nil }
    // Batch parse of the scanned signed session back into N signed PCZTs — [ext], same ask. Input type
    // matches the scan-checker plumbing (the accumulated UR; prefer a Data/cbor-based signature if the
    // URKit type isn't Sendable-friendly — implementer resolves against ScanChecker.swift's shapes).
    var parseMigrationPCZTBatch: @Sendable (Data) -> [Pczt]? = { _ in nil }
    // Lifecycle — Kotlin: initializePostUpgrade
    var initializeMigrationPostUpgrade: @Sendable () -> Void = { }                                            // [draft]
}

