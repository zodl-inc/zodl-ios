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
    
    let prepareWith: @Sendable ([UInt8], BlockHeight?, String, String?) async throws -> Initializer.InitializationResult
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
    /// MOB-1513: proposes the immediate (single-transaction) migration — an ordinary send-max
    /// proposal (NOT an engine-held schedule; no plan-cache staleness applies to it). Execute it via
    /// `createAndSubmitProposedTransactions(proposal.proposal, usk)` (software) or
    /// `createPCZTFromProposal(accountUUID, proposal.proposal)` (Keystone) exactly like any other
    /// ordinary transfer, then call `recordImmediateMigration` after a successful broadcast.
    var proposeImmediateMigration: @Sendable (AccountUUID) async throws -> ImmediateMigrationProposal
    /// MOB-1513: records a broadcast immediate-migration sweep so the platform migration state
    /// machine reports it (`InProgress` 0-of-1 while unmined, `Complete` once mined). NOT
    /// broadcast-sensitive itself (the broadcast already rode the already-guarded
    /// `createAndSubmitProposedTransactions`/`createAndSubmitTransactionFromPCZT` closures) — no
    /// transaction-guard wrap here. `txid` is the SDK's raw/internal byte order (32 bytes; matches
    /// `TxId.id`, NOT the reversed display-hex order `Data.toHexStringTxId()` produces).
    var recordImmediateMigration: @Sendable (AccountUUID, Data) async throws -> Void
    /// The leftover Orchard balance a migration would not cross, when worth offering a choice
    /// about; `nil` when there is none. THROWS before the wallet's first completed sync.
    var residualAfterMigration: @Sendable (AccountUUID) async throws -> Zatoshi?
    /// MOB-1496: locks every currently-spendable legacy-Orchard note of the account until explicit
    /// unlock and returns the total value just locked — the "Lock balance" choice at migration
    /// `Complete`. `Zatoshi(0)` is a legitimate result; idempotent-additive (repeating the call
    /// locks only notes that became spendable since); a concurrent-lock race throws and is
    /// retry-safe. NOT broadcast-bearing (no transaction-guard wrap).
    var lockMigrationResidual: @Sendable (AccountUUID) async throws -> Zatoshi
    /// MOB-1496: clears ALL of the account's output locks — the release half of
    /// `lockMigrationResidual` — and returns the number of outputs unlocked (`0` when nothing was
    /// locked). "Migrate anyway" over a locked residual is this call followed by
    /// `proposeImmediateMigration`: locked notes are excluded from note selection, so the unlock
    /// must come first. NOT broadcast-bearing (no transaction-guard wrap).
    var unlockMigrationResidual: @Sendable (AccountUUID) async throws -> Int
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
    /// MOB-1511 (W2): the engine's estimate of how many migration runs ("rounds") the account's
    /// balance needs in total. STUB — always `nil` today: the estimator
    /// (`estimate_migration_runs` -> `MigrationRunEstimate.run_count()`) lives in
    /// librustzcash#2714, unmerged and not yet plumbed through FFI/SDK. When it lands, swap the
    /// live stub body for the real `Synchronizer` call; the UI already renders "Round N of M"
    /// whenever this returns a value and "Round N" while it stays `nil`.
    var estimateMigrationRunCount: @Sendable (AccountUUID) async throws -> Int? = { _ in nil }
    /// Re-proposes at a fresh anchor and re-signs the account's active run (needs the USK); returns
    /// the number refreshed.
    var refreshStaleMigrationTransfers: @Sendable (
        AccountUUID, UnifiedSpendingKey, _ includeResidual: Bool
    ) async throws -> UInt32
    /// [ext] MOB-1487 R3: would a regular send of `amount` draw on (unlocked) Orchard notes? Drives
    /// the send-form privacy disclaimer once Ironwood is active. Non-throwing: degrades to `false`
    /// (matches the pre-real-SDK stub's permissive default) on any read error.
    var sendRequiresOrchardFunds: @Sendable (AccountUUID, Zatoshi) async -> Bool = { _, _ in false }
    // MOB-1496 (W-B): the old engine-schedule-based dust composite (`migrateMigrationDust`) is
    // retired — "Migrate anyway" now rides the same `proposeImmediateMigration` +
    // `createAndSubmitProposedTransactions`/`createPCZTFromProposal` lane as the entry-screen
    // immediate migration, unlock-first (`unlockMigrationResidual`, above). `lockMigrationDust`/
    // `isMigrationDustLocked` are app persistence, not SDK calls — see `MigrationManagerClient`.
    // Keystone (PCZT)
    /// Builds the account's whole previewed Keystone migration commit UNSIGNED and returns the
    /// preparation (note-split) subset for the signing ceremony — empty when no preps are needed.
    /// MOB-1496 (final engine): this is the RUN-CREATING call — the engine commits the previewed
    /// plan (every transaction in the run, preps AND the schedule's own transfers, not just the
    /// subset returned here) the moment it's called, and always resumes a stored non-terminal run on
    /// the next attempt, ignoring any newer preview. A ceremony abandoned after this call must
    /// explicitly cancel the run it just created (`restartCurrentMigrationStep`) or a later re-entry
    /// will silently resume signing these same, by-then-stale PCZTs instead of proposing a fresh one.
    var proposeNoteSplitPCZTs: @Sendable (AccountUUID) async throws -> [MigrationUnsignedTransferPczt]
    /// Stores Keystone-signed note-split preparation PCZTs — thin wrap of
    /// `storeSignedNoteSplitPCZTs(accountUUID:_:)`, discarding the returned
    /// `PreparedMigrationTransfer` (a storage receipt with a zeroed txid — the broadcastable value
    /// comes from `broadcastStoredNoteSplit`). All-or-nothing: every signed PCZT in the array is
    /// applied together. MOB-1496 (final engine): the old singular pair's C-1/C-1b run-shadowing
    /// hazard — "this store unconditionally starts a new run, so it MUST precede
    /// `storeSignedMigrationTransactions` or a shadow run strands the schedule" — is GONE: the run is
    /// created at PCZT-build time (`proposeNoteSplitPCZTs`, above), the engine refuses to double-commit
    /// a run, and this store and `storeSignedMigrationTransactions` are now order-independent
    /// per-transaction signature applications over the SAME already-created run. NOTE: the app still
    /// stores these preps before broadcasting them (`broadcastStoredNoteSplit`) — the resume/retry lane
    /// depends on stored-before-broadcast — but that ordering is an app-side choice now, not an engine
    /// requirement. NOT guard-wrapped: local store, no broadcast — same reasoning as
    /// `storeSignedMigrationTransactions`.
    var storeSignedNoteSplits: @Sendable (AccountUUID, [MigrationSignedTransferPczt]) async throws -> Void
    /// Broadcasts the Keystone note-split preps already stored via `storeSignedNoteSplits`, through
    /// `executeNextPendingMigrationTransfer`. Idempotent by construction — a retry simply re-asks the
    /// engine what's next-due, never re-stores — unlike the deleted `submitSignedNoteSplit` composite
    /// this pair replaces, whose retry re-ran the (by-then-already-consumed) store and threw. Guard-
    /// wrapped: broadcast-bearing.
    var broadcastStoredNoteSplit: @Sendable (AccountUUID, MigrationNetworkPrivacyOptions) async throws -> MigrationTransferResult
    var proposeMigrationPCZTs: @Sendable (AccountUUID, MigrationSchedule) async throws -> [MigrationUnsignedTransferPczt]
    var storeSignedMigrationTransactions: @Sendable (AccountUUID, [MigrationSignedTransferPczt]) async throws -> Void
    // Batch UR encoding of N migration PCZTs into ONE animated-QR session — [ext]: JOINT SDK +
    // Keystone-team ask; device support unvalidated (feature-spec §14 risk).
    var urEncoderForMigrationPCZTBatch: @Sendable ([MigrationUnsignedTransferPczt]) -> UREncoder? = { _ in nil }
    // Batch parse of the scanned signed session back into N signed PCZTs' raw bytes, in scan order.
    var parseMigrationPCZTBatch: @Sendable (Data) -> [Data]? = { _ in nil }
}

extension SDKSynchronizerClient {
    /// MOB-1496 (W3 review fix A): the single stop-before-broadcast guard for EVERY foreground
    /// migration broadcast lane (`MigrationSendingStore`, `MigrationNoteSplitStore`,
    /// `MigrationTransferPlanStore`, `MigrationReviewTransferStore`) — hoisted out of four per-store
    /// duplicates (the original W3 sweep only reached the first two; the silent note-split broadcast
    /// under the TransferPlan/ReviewTransfer commit CTAs, MOB-1478 W4, was missed). Sync and
    /// migration broadcasts must never share a session: the SDK's during-sync throw
    /// (`ZcashError.migrationBroadcastDuringSync`) is only advisory/point-in-time, so callers stop
    /// proactively instead of relying on it. Idempotent: a no-op when nothing is syncing.
    ///
    /// R9-T7 (MOB-1497 review remediation, finding 9): the BACKGROUND broadcast lane
    /// (`RootInitialization.executeBroadcastAction`) now calls this too — it was the one broadcast
    /// entry point still relying solely on the SDK's own during-sync throw, which never itself
    /// resumes sync afterward (unlike this method's own `migrationStoppedSyncForBroadcast` flag,
    /// which Root's `.migrationSyncGateChanged` handler consumes to guarantee a resume). Every
    /// broadcast-performing call site in the app now stops sync first.
    ///
    /// MOB-1496 (W3 review fix B): when this DOES stop an in-flight sync, it also flips the shared
    /// `migrationStoppedSyncForBroadcast` flag (`@Shared(.inMemory(...))`, same idiom as
    /// `selectedWalletAccount`) — never when idle. `RootInitialization.swift`'s
    /// `.migrationSyncGateChanged` handler reads this to guarantee sync resumes once the SDK's
    /// post-broadcast privacy gate clears, even when no start was concurrently deferred (the
    /// original W3 mechanism only resumed a start that was itself caught mid-`.retryStart`). See
    /// that handler's doc for the full mechanism, including the pre-flight-broadcast-failure edge
    /// where the gate never blocks at all.
    func stopSyncBeforeMigrationBroadcast() async {
        guard isSyncing() else { return }
        stop()
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        $migrationStoppedSyncForBroadcast.withLock { $0 = true }
    }
}
