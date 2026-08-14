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
    
    /// Seed is OPTIONAL: pass it only on first init (account import). Once the wallet exists in
    /// `data.db`, pass `nil` — the SDK prepares from the stored accounts and the seed never needs to
    /// be decrypted at launch (see docs/macos/KEYCHAIN_SE_HARDENING.md).
    let prepareWith: @Sendable ([UInt8]?, BlockHeight?, String, String?) async throws -> Initializer.InitializationResult
    let start: @Sendable (_ retry: Bool) async throws -> Void
    let stop: @Sendable () -> Void
    let isSyncing: @Sendable () -> Bool
    let isInitialized: @Sendable () -> Bool

    let importAccount: @Sendable (String, [UInt8]?, Zip32AccountIndex?, AccountPurpose, String, String?, BlockHeight?) async throws -> AccountUUID?
    var deleteAccount: @Sendable (AccountUUID) async throws -> Void

    // MARK: - Migration (Orchard -> Ironwood)
    //
    // The SDK's migration group lives on `Synchronizer` and needs no `prepare()`. Declarations are
    // #1930's verbatim (map §4.1a: already 1:1 with the new SDK); each phase binds the subset it
    // needs — Phase 1 the banner state read, Phase 2 the two propose lanes below.

    /// What this account's migration needs NEXT, decided by the engine from persisted state alone —
    /// `nil` when no run is stored. The step (``MigrationAdvance/step``) is the replacement for the
    /// retired 5-case `MigrationState`: that enum conflated "what is true" with "what to do", and
    /// every app-side consumer actually wanted the latter. The wrapper also carries the engine's
    /// advisory OUTLOOK (``MigrationAdvance/next``): when, and of what kind, the migration next has
    /// serviceable work assuming this step is executed — `nil` when nothing is height-schedulable.
    /// One step of lookahead, superseded by the next read; consumed by the driver's arming pass and
    /// never cached across state changes.
    ///
    /// Priority is BROADCAST > PROVE > REBUILD, and that ordering is load-bearing: ZIP 318 wants a
    /// waking session used either to sync or to broadcast, never both, so surfacing every due
    /// broadcast first is what makes a sync-free broadcast session possible. The step is memoryless
    /// about sessions — it says WHAT, the app says WHEN (which visit type). See
    /// `MigrationManagerImpl` for the app's own session policy.
    let migrationAdvanceStep: @Sendable (AccountUUID) async throws -> MigrationAdvance?
    /// The full scheduled-migration schedule for the account's spendable Orchard balance.
    let proposeMigrationTransfers: @Sendable (AccountUUID) async throws -> MigrationSchedule
    /// Proposes the immediate (single-transaction) migration — an ordinary send-max proposal,
    /// engine-external: submit it through the ordinary transfer pipeline, then call
    /// `recordImmediateMigration` after a successful broadcast.
    let proposeImmediateMigration: @Sendable (AccountUUID) async throws -> ImmediateMigrationProposal
    /// Records a broadcast immediate-migration sweep so the platform migration state machine
    /// reports it. Takes the RAW/internal-order txid, not the display-hex form — see
    /// `MigrationCommitPipeline.rawTxId(fromDisplayHex:)`.
    let recordImmediateMigration: @Sendable (AccountUUID, Data) async throws -> Void
    /// Restarts the current migration step, returning the re-created schedule.
    let restartCurrentMigrationStep: @Sendable (AccountUUID) async throws -> MigrationSchedule
    /// The engine's estimate of how many migration runs ("rounds") migrating the account's whole
    /// Orchard balance will take. `nil` when the estimate is unavailable or has no runs.
    let estimateMigrationRunCount: @Sendable (AccountUUID) async throws -> Int?
    /// D14: how many note-PREPARATION transactions the account's NEXT run will take, from the same
    /// `estimateMigrationRuns` call `estimateMigrationRunCount` reads — the pre-commit counterpart
    /// to the post-commit `.preparation`-kind rows in `migrationTransactionStatuses`.
    ///
    /// Read off the FIRST run: the plan the user is about to confirm is always the next one, and
    /// later runs' preparation counts are re-estimated when their own turn comes. `nil` when the
    /// estimate is unavailable or has no runs — callers fall back to showing one split row, which
    /// is what every plan showed before D14.
    ///
    /// Deliberately a sibling member rather than a widening of `estimateMigrationRunCount`'s return
    /// type: the round-count call site (`MigrationManagerImpl.migrationRoundContext`) and this one
    /// want different fields of the same estimate, and two narrow members keep both call sites and
    /// every `SDKSynchronizerTest` shape honest without a tuple no one destructures whole.
    let estimateMigrationPreparationCount: @Sendable (AccountUUID) async throws -> Int?

    // PHASE 3 — the scheduler. Commit, the broadcast loop, and the reads the loop reconciles from.

    /// The account's LIVE per-transaction migration statuses — one row per committed migration
    /// transaction (preparation AND transfer kinds), mined-reconciled at every read; `[]` when no
    /// run is stored. Preferred over the persisted schedule's own app-derived state/heights by
    /// `MigrationDerivations.transferRows` for every row it can join by id.
    let migrationTransactionStatuses: @Sendable (AccountUUID) async throws -> [MigrationTransactionStatus]
    /// Pre-signs and persists every transfer of `schedule` in the migration engine (needs the
    /// account's USK). THE commit — one call signs the whole run, preparation layers included,
    /// straight from the plan cache the schedule's own propose already wrote.
    let signAndStoreMigrationSchedule: @Sendable (AccountUUID, MigrationSchedule, UnifiedSpendingKey) async throws -> Void
    /// THE BROADCAST EXECUTOR. Submits the already-proven transaction `instruction` names and
    /// returns the recorded result directly. Broadcast-bearing: guarded by the transaction guard in
    /// the LiveKey.
    ///
    /// There are no outcome cases left to collapse. The instruction is the payload of a
    /// `.broadcast` step a crank handed out, so "nothing due" cannot arise, and a due-but-unproved
    /// row arrives as a `.prove` batch entry rather than as a delivery outcome. No `useEstimatedTip`
    /// either — the conduit always projects the estimate, so the acceleration is applied once, at
    /// the crank.
    ///
    /// Throws `ZcashError.rustMigrationTakeBroadcastTransaction` when the instruction went STALE
    /// between crank and submit: crank `migrationAdvanceStep` again, never retry the executor.
    let performMigrationBroadcast: @Sendable (
        AccountUUID, MigrationBroadcastInstruction, MigrationNetworkPrivacyOptions
    ) async throws -> MigrationTransferResult
    /// Whether the account has a scheduled transfer past its send height but not yet broadcast.
    /// `useEstimatedTip` as above — pass `true` on SEND visits and launch checks.
    let hasOverdueMigrationTransfers: @Sendable (AccountUUID, Bool) async throws -> Bool
    /// THE PROVE EXECUTOR. Proves up to `maxProofs` of the transactions the instruction batch
    /// names and returns a `MigrationProveOutcome`: how many were proved (`0` is the ordinary
    /// "nothing in this batch is provable right now" answer) and THE TXIDS OF THE PREPARATIONS it
    /// proved. Run at SYNC visits once sync reaches the tip, NEVER in a broadcast session.
    ///
    /// The batch is the payload of a `.prove` step a crank handed out — this executor never asks
    /// the engine what to prove. There is no loop inside it: proving can unblock rows the batch did
    /// not name, so a host draining the run cranks again. A skipped row (already proved, anchor
    /// unresolvable) does NOT spend the budget, and acting on a stale batch is safe.
    ///
    /// `maxProofs` must be >= 1 or the call throws `rustMigrationProveTransactions`. Proving has no
    /// deadline — boundary checkpoints are durably retained until the transfer is broadcast — so a
    /// bounded budget only defers work, never loses it.
    ///
    /// The returned txids are the handoff to `takeMigrationPreparation`: a proved preparation is
    /// submitted by the APP, the ordinary way. Transfers are never named, so the caller makes no
    /// kind judgement of its own.
    let proveMigrationTransactions: @Sendable (AccountUUID, [MigrationProveTarget], Int) async throws -> MigrationProveOutcome
    /// THE PREPARATION ACCESSOR. Serves the proved preparation `txid` names — one the outcome of
    /// `proveMigrationTransactions` just returned — for submission.
    ///
    /// A proved preparation is a complete PCZT; preparations are ZIP 318-exempt and the engine's
    /// contract is that one is broadcast as soon as it is proved, so its submission is the app's
    /// ORDINARY path rather than a delivery session. THE ACCESSOR IS THE SEAM: the wallet's own
    /// record of the transaction binds AT RETRIEVAL, in the same database transaction that hands
    /// the bytes back, and re-retrieving after a crash serves the same bytes over the same record —
    /// so call it AT SUBMISSION TIME, never eagerly.
    ///
    /// PREPARATION-GATED: a transfer's txid is refused with
    /// `ZcashError.rustMigrationTakePreparation`, as an unknown or not-yet-proved one is. The
    /// returned `PreparedMigrationTransfer.id` is the ENGINE TRANSFER ID the record path keys on;
    /// its `pczt` is a finalized consensus transaction, submittable as-is.
    let takeMigrationPreparation: @Sendable (AccountUUID, Data) async throws -> PreparedMigrationTransfer
    /// Submits an already-finalized migration preparation through the app's ORDINARY
    /// raw-transaction submission machinery — the same `submitCreatedTransactions` /
    /// `Broadcaster.submit(transaction:to:)` path, endpoint selection and result mapping that
    /// `createAndSubmitProposedTransactions` uses, entered with bytes the migration engine built
    /// instead of ones the proposal path did. Not a parallel submit lane: nothing here is
    /// migration-specific except where the bytes came from.
    let submitMigrationPreparation: @Sendable (PreparedMigrationTransfer) async throws -> CreateProposedTransactionsResult
    /// CLOSES THE SEAM: records the ENGINE-side outcome of a preparation this app retrieved and
    /// submitted itself. `takeMigrationPreparation` bound the wallet's own record at retrieval,
    /// but the engine's per-row `Proved -> Broadcast` mark is what `performMigrationBroadcast`
    /// makes on its success arm — a path a self-submitted preparation never travels.
    ///
    /// Takes the `PreparedMigrationTransfer` the accessor returned (its `id` is the engine
    /// transfer id the record path keys on) and is preparation-gated in the same register: a
    /// transfer's id is refused with `ZcashError.rustMigrationRecordTransferResult`, since that
    /// lane records its own outcome. Call it on an ACCEPTANCE only — the engine's network-error
    /// outcome records nothing by design.
    let recordMigrationPreparationBroadcast: @Sendable (
        AccountUUID, PreparedMigrationTransfer, MigrationTransferResult
    ) async throws -> Void
    /// The minimal set of heights at which to wake, sync and prove. Jitter is re-drawn per call, so
    /// these must be recomputed after any state change rather than cached.
    let migrationSyncWakeups: @Sendable (AccountUUID) async throws -> [MigrationSyncWakeup]
    /// The projected chain tip, measured from recently scanned block headers — height→wall-clock math
    /// for notification scheduling, and due-ness reasoning between syncs.
    let estimatedMigrationChainTip: @Sendable () async throws -> BlockHeight
    /// The measured seconds-per-block used by `estimatedMigrationChainTip` (clamped 5–150 s, 75 s
    /// fallback) — the height→time conversion factor for notification fire times.
    let estimatedMigrationSecondsPerBlock: @Sendable () async throws -> Double
    /// Wallet-scope: whether ordinary sync should currently be paused for a migration privacy gate.
    /// Non-throwing (degrades open on internal failure).
    var isMigrationSyncBlocked: @Sendable () async -> Bool = { false }
    /// Wallet-scope stream of `isMigrationSyncBlocked()`. Root subscribes this to drive the
    /// stop/resume pair — see `stopSyncBeforeMigrationBroadcast()` below.
    var migrationSyncBlockedStream: @Sendable () -> AnyPublisher<Bool, Never> = { Empty().eraseToAnyPublisher() }
    /// The run's live progress (completed/total transfers), or `nil` when no run is stored. Feeds
    /// the in-progress banner variant and the re-entry route.
    let getMigrationProgress: @Sendable (AccountUUID) async throws -> MigrationProgress?
    /// Whether the account's migration is in an invalid state (spendable Orchard remains but no
    /// scheduled transfer covers it). Read by `reentryRoute`; its recovery SCREEN is Phase 5.
    let hasInvalidMigrationTransfers: @Sendable (AccountUUID) async throws -> Bool
    /// The leftover Orchard balance a migration would not cross, when worth offering a choice
    /// about; `nil` when there is none. Feeds `migrationSummary.dust`.
    let residualAfterMigration: @Sendable (AccountUUID) async throws -> Zatoshi?
    /// Locks every currently-spendable legacy-Orchard note until explicit unlock and returns the
    /// total just locked — the "Lock balance" choice at migration Complete. The SCREEN that offers
    /// it is Phase 6; the member is bound here because the manager (copied whole from #1930) calls
    /// it, and a live binding is safer than a stub that silently no-ops a real lock.
    let lockMigrationResidual: @Sendable (AccountUUID) async throws -> Zatoshi
    /// PHASE 6: releases a previously locked residual so it can be swept — the "Migrate anyway"
    /// fork's first step. Returns the number of notes unlocked.
    let unlockMigrationResidual: @Sendable (AccountUUID) async throws -> Int

    // PHASE 7 — the Keystone lane (REBUILD_PLAN D15). Two groups: the PCZT serve/store pair that
    // creates and completes a hardware-signed run, and the batch-signing bridge that carries one
    // ceremony's PCZTs to the device and its signatures back. None of the six is broadcast-bearing
    // (the actual broadcast still rides `performMigrationBroadcast` for the scheduled lane
    // and `createAndSubmitTransactionFromPCZT` for the immediate one), so none takes the transaction
    // guard in the LiveKey.

    /// Builds the account's whole previewed Keystone migration commit UNSIGNED and returns the
    /// preparation (note-split) subset for the signing ceremony — empty when no preps are needed.
    ///
    /// ⚠️ THIS IS THE RUN-CREATING CALL. The engine commits the previewed plan (every transaction in
    /// the run — preps AND the schedule's own transfers, not just the subset returned here) the
    /// moment it is called, and thereafter always resumes that stored non-terminal run, ignoring any
    /// newer preview. A ceremony abandoned after this call MUST explicitly cancel the run it just
    /// created (`restartCurrentMigrationStep`) or a later re-entry silently resumes signing these
    /// same, by-then-stale PCZTs. That is why every abandon path in `MigrationCoordFlowCoordinator`
    /// is mandatory, not best-effort.
    let proposeNoteSplitPCZTs: @Sendable (AccountUUID, MigrationSchedule) async throws -> [MigrationUnsignedTransferPczt]
    /// Stores Keystone-signed note-split preparation PCZTs. All-or-nothing: every signed PCZT in the
    /// array is applied together. Order-independent with `storeSignedMigrationTransactions` — both
    /// are per-transaction signature applications over the SAME already-created run (see
    /// `proposeNoteSplitPCZTs`). The returned storage receipt is discarded; the broadcastable value
    /// comes from the instruction a `migrationAdvanceStep` crank hands to `performMigrationBroadcast`.
    let storeSignedNoteSplits: @Sendable (AccountUUID, [MigrationSignedTransferPczt]) async throws -> Void
    /// Serves the run's TRANSFER PCZTs unsigned. Handle-free: it resumes the run
    /// `proposeNoteSplitPCZTs` created rather than committing a new one.
    let proposeMigrationPCZTs: @Sendable (AccountUUID, MigrationSchedule) async throws -> [MigrationUnsignedTransferPczt]
    /// Stores the Keystone-signed transfer PCZTs, completing the run's signing. All-or-nothing.
    let storeSignedMigrationTransactions: @Sendable (AccountUUID, [MigrationSignedTransferPczt]) async throws -> Void
    /// Splits an ordered PCZT batch into device-sized signing sessions by ACTION budget, not by
    /// transaction count. A preparation weighs 16 actions and a transfer 3, so counting transactions
    /// undercounts: 6 preparations + 1 transfer is 99 actions — two Keystone rounds, where any
    /// count-based ceiling of 7-or-more claimed one. Order-preserving.
    ///
    /// Must be called BEFORE signing: rows returned by `applyKeystoneBatchSignatures` carry `0`
    /// actions (reconstructed from retained bytes, no engine context) and would throw here.
    let batchMigrationPcztsForSigning: @Sendable ([MigrationUnsignedTransferPczt], Int) async throws -> [[MigrationUnsignedTransferPczt]]

    /// Builds the animated QR frame strings for a Keystone batch-signing request over `pczts` (which
    /// MUST be preparation-then-transfer, schedule order — see the SDK doc). The SAME array, in the
    /// SAME order, must be passed to `applyKeystoneBatchSignatures` once the device responds: the
    /// signatures come back positionally, with no PCZT echoed.
    let buildKeystoneSignBatchQRParts: @Sendable (Data, [MigrationUnsignedTransferPczt], Int) async throws -> [String]
    /// Discards any in-flight batch-response decode session — call on scan-screen entry, retry and
    /// exit (one decode session exists process-wide). Infallible.
    let resetKeystoneSignBatchDecoder: @Sendable () async -> Void
    /// Feeds one scanned QR frame into the active decode session. The second argument is the
    /// ceremony's `requestId`, round-tripped by the device: a mismatch rejects a stale or unrelated
    /// scan rather than decoding it.
    let decodeKeystoneSignBatchPart: @Sendable (String, Data) async throws -> KeystoneBatchDecodeResult
    /// Applies the ceremony's batch signatures to `pczts` POSITIONALLY — must be the same array and
    /// order passed to `buildKeystoneSignBatchQRParts`, including its unredacted bytes.
    let applyKeystoneBatchSignatures: @Sendable ([MigrationUnsignedTransferPczt], Data) async throws -> [MigrationSignedTransferPczt]
    /// Rebuilds every EXPIRED transfer of the stored run in place and returns the run's full
    /// post-refresh schedule. `usk: nil` is the external-signer (Keystone) lane — rebuilt rows are
    /// left UNSIGNED (same funding note, recovered by nullifier identity; fresh scheduled height,
    /// expiry and drawn boundary) and flow back through the ceremony. NEVER pass `nil` for a
    /// software account: its rows would strand awaiting a ceremony that never comes.
    ///
    /// The returned schedule is the persisted truth — a later consent echo that replays a
    /// pre-refresh copy fails with `migrationPlanStale` from then on.
    let refreshStaleMigrationTransfers: @Sendable (AccountUUID, UnifiedSpendingKey?) async throws -> MigrationSchedule

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
    /// [#1755] v0.7 P1b: replaces the slipstream engine's alternate-server list — the
    /// per-pass probe grid + mid-pass failover candidates. Consent-gated by the user's
    /// connection mode exactly like submission fan-out: Automatic -> all known servers,
    /// Manual -> EMPTY (the pinned server is used exclusively; probe and failover never
    /// run). No-op on the old SDKSynchronizer engine.
    var setAlternateEndpoints: @Sendable ([LightWalletEndpoint]) async -> Void
    
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
}

extension SDKSynchronizerClient {
    /// Stops an in-flight sync ahead of a migration broadcast, so the broadcast is not correlated
    /// with the wallet's ordinary sync traffic. EVERY broadcast-performing call site in the app
    /// calls this first — the SDK's own during-sync throw is an advisory backstop, not the guard.
    ///
    /// The `migrationStoppedSyncForBroadcast` flag is the OTHER half of the pair and the reason
    /// this must never ship alone (matrix B12): `RootInitialization`'s `.migrationSyncGateChanged`
    /// handler consumes it to guarantee sync resumes once the SDK's post-broadcast privacy gate
    /// clears — including the edge where the broadcast fails pre-flight and the gate never blocks
    /// at all. Set only when this call ACTUALLY stopped something; never when already idle, or the
    /// resume half would fire against a sync nobody paused.
    func stopSyncBeforeMigrationBroadcast() async {
        guard isSyncing() else { return }
        stop()
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        $migrationStoppedSyncForBroadcast.withLock { $0 = true }
    }

    /// The migration GATE's stop — the sibling of `stopSyncBeforeMigrationBroadcast()` above, with
    /// a deliberately different predicate. The broadcast lanes stop a scan that is IN FLIGHT
    /// (`isSyncing()`), because that is what would correlate with their submit. The gate's stop
    /// exists for the opposite state: a STARTED engine idling at the tip (`.upToDate`), completing
    /// a pass on every new block — each completion re-arms the app-side send window, which is the
    /// foreground broadcast wedge (field-caught 2026-08-02). `isSyncing()` is false there, so the
    /// broadcast lanes' guard would no-op in exactly the state this call is for. "Started" here is
    /// `.syncing` OR `.upToDate`; a `.stopped`/`.unprepared`/`.error` engine has nothing to stop,
    /// and the resume flag must not be armed for a sync nobody paused (the same B12 contract as
    /// the sibling).
    func stopStartedSyncForMigrationGate() async {
        let status = latestState().syncStatus
        let isStarted: Bool
        switch status {
        case .syncing, .upToDate:
            isStarted = true
        default:
            isStarted = false
        }
        guard isStarted else { return }
        stop()
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        $migrationStoppedSyncForBroadcast.withLock { $0 = true }
    }
}

