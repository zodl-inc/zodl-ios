//
//  MigrationManagerLiveKey.swift
//  Zashi
//
//  Live implementation of `MigrationManagerClient`. Every piece of actual logic is factored
//  into pure, table-testable types below (`MigrationDerivations`, `MigrationGateStorage`) so
//  `MigrationManagerTests` can exercise them without touching the SDK; this file is left with
//  only the wiring between those types and `@Dependency(\.sdkSynchronizer)` /
//  `@Dependency(\.zcashSDKEnvironment)`.
//
//  MOB-1496: `bannerVariant`/`reentryRoute`/`reconcile` now read the real per-account,
//  throwing SDK surface — every SDK read degrades to a safe default (false/nil/entry) on either a
//  missing selected account or a thrown error, so a migration-surface hiccup never crashes launch,
//  foreground entry, or the smart banner. `migrationSummary`/`migrationTransfers`/`lockMigrationDust`/
//  `isMigrationDustLocked`/`stateEvents` are new here — relocated from `SDKSynchronizerClient`
//  (summary/transfers/dust-lock are app-side derivations/persistence, not SDK calls; stateEvents is
//  the per-account replacement for the old wallet-wide `migrationStateStream`).
//
//  MOB-1496 (W3) split the privacy gate across the SDK and this client: the SDK owned
//  broadcast->sync, this client owned sync->send via a post-sync cooldown. BOTH timed halves are
//  gone as of 2026-08-07. A fixed delay either side of the pair is an identifiable pattern rather
//  than a defense against one, so neither direction is paced by a clock now. What remains is the
//  SDK's present-tense hold — a submission actually in flight
//  (`SDKSynchronizerClient.isMigrationSyncBlocked`/`migrationSyncBlockedStream`, driven from
//  `RootInitialization.swift`'s `.retryStart`/`.migrationSyncGateChanged`) — plus this app's
//  stop-sync-before-broadcast sequencing. `recordSyncCompleted` survives, but purely as the
//  snapshot-republish edge it also always was; it no longer stamps a timestamp.
//
//  MOB-1497 (T1 of the Tor & broadcast-routing requirements round): four changes to the network
//  snapshot. (1) Forming moves from the first broadcast-bearing `migrationNetworkOptions` read to
//  the Tor-choice step (`formNetworkSnapshot`, called by the coordinator), with a provisional-
//  until-commit lifecycle — `MigrationNetworkSnapshot.committedAt` is nil until
//  `markNetworkSnapshotCommitted` stamps it (co-located inside `recordCommittedSchedule`, its one
//  production call site); a provisional snapshot is discarded at flow teardown
//  (`clearProvisionalNetworkSnapshot`) rather than surviving to be silently reused, and survives a
//  background reconcile's stale-`.notStarted` observation (`clearIfCommitted`, not the old
//  unconditional `clear`) so a user mid-flow never has their just-formed pick wiped out from under
//  them. `ensureNetworkSnapshot` (the old entry point) is now the safety net for a lane that never
//  formed one, sharing `ensureOrCreateNetworkSnapshot`'s body with `formNetworkSnapshot` and
//  stamping committed immediately on creation. (2) R7: `createNetworkSnapshot`'s broadcast pick is
//  now a uniform-random draw (`@Dependency(\.migrationRandomness)`) over the other provider's
//  shipped endpoints, replacing `evaluateBestOf` entirely — creation now makes zero network calls.
//  (3) R8: custom-server detection is identity-based only — the stored `ServerConfig.isCustom` flag
//  is no longer read here. (4) R1: `MigrationGateStorage.isTorEnabledForMigration()`'s never-
//  written default flips from `false` to `true`; the identity-custom forced-false (R2's data half)
//  still wins over either the default or an explicit stored choice.
//
//  MOB-1497 (R7 adversarial-review fix, Important-1): `ensureOrCreateNetworkSnapshot` used to return
//  ANY existing snapshot before creating, regardless of committed/provisional state — so a stale
//  PROVISIONAL snapshot left behind by an abandoned attempt (app killed before commit, or a
//  same-session back-and-reconfirm) would silently win over a fresh Tor choice made at a later
//  attempt's Tor-choice step, in the worst case broadcasting over clearnet under a screen that showed
//  Tor ON. Fixed with a `reformIfProvisional` flag threaded through `ensureOrCreateNetworkSnapshot`:
//  `true` for `formNetworkSnapshot` (a still-provisional existing snapshot is discarded and re-formed
//  from the current stored choice plus a fresh random roll — always safe, since nothing has broadcast
//  against an uncommitted snapshot), `false` for `ensureNetworkSnapshot` (the broadcast-time safety
//  net stays strictly idempotent against a provisional snapshot too, so R7's "held for the run" isn't
//  broken for a mid-run/BG-executor caller). A COMMITTED existing snapshot is never reformed by
//  either path.
//
//  MOB-1497 (R9-T6, finding 8): `ensureOrCreateNetworkSnapshot`'s create path no longer takes
//  `transactionGuard` — the app-wide FIFO mutex shared with `createProposedTransactions`/
//  `createTransactionFromPCZT`/`getTreeState`/vote submission/server switches. Forming was queueing
//  behind whatever ELSE happened to be broadcasting (another account's Tor bootstrap + submit, for
//  one) for no reason: forming never touches the live synchronizer. Its reads/writes are
//  `zcashSDKEnvironment.endpoint()` (UserDefaults-backed), the migration gate's Tor flag
//  (UserDefaults, self-locked), `migrationRandomness.randomIndex` (pure), and `snapshotStorage`
//  (every call atomic under its own `OSAllocatedUnfairLock`) — the hazard the guard exists for
//  (`switchTo(endpoint:)` tearing down the synchronizer under an in-flight broadcast) cannot reach
//  any of that. The routing layer's own snapshot mutations (`rotateBroadcastEndpoint`,
//  `overrideUseTorOnActiveSnapshot`, `overrideBroadcastEndpointToSyncServerOnActiveSnapshot`) were
//  already guard-free by this same reasoning — forming was the odd one out. `MigrationManagerImpl`
//  no longer holds a `transactionGuard` dependency at all.
//
//  The ONE thing the guard incidentally provided — closing the "check absent -> create -> write"
//  race between two concurrent formers for the SAME account — is re-closed at the storage layer:
//  `MigrationSnapshotStorage.ensureOrCreate(candidate:reformIfProvisional:for:)` folds the decide-
//  and-write into ONE `PerAccountCodableStorage.modify` closure. The caller computes the candidate
//  snapshot (the only `await`s — endpoint/Tor-flag/random-pick reads) BEFORE calling in, since
//  `modify`'s closure is synchronous; `ensureOrCreate` then re-checks the SAME reuse condition
//  (`existing.committedAt != nil || !reformIfProvisional`) against whatever is ACTUALLY persisted
//  at the instant its lock is held — a competing former's already-written value wins if it
//  satisfies the condition, this call's candidate otherwise — and returns whichever one is now
//  actually stored. Every caller therefore gets back a value consistent with storage, never a
//  value a concurrent write has already superseded.
//
//  MOB-1497 (T5) — DELETED (audit 2026-08-03, #16): the "pending background Tor prompt" latch
//  is gone. Its named arm site (`RootInitialization.executeBroadcastAction`) never existed and its
//  sheet was never presented, so it could neither be set nor consumed; `markHadBroadcast`/`clear`
//  still remove any value an older build persisted under its key.
//

import Foundation
@preconcurrency import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import os
import UserNotifications

extension MigrationTransferProposal {
    /// OLD -> NEW SDK: `MigrationTransferProposal.id` is a `UInt32` engine ordinal in the new SDK
    /// (`Model/MigrationModels.swift:196`); in #1930 it was already a `String`. Every app-side model
    /// that carries a transfer id — `MigrationCommittedSchedule.SentRecord.transferId`,
    /// `MigrationTransferRow.id` — keys on `String`, and #1930's own status join already wrote
    /// `String(status.id)` for exactly this reason.
    ///
    /// Stringifying is the SDK's own sanctioned join, not a workaround: `MigrationTransactionStatus
    /// .id`'s doc states `String(status.id)` equals `MigrationTransferProposal.id` for the same
    /// transaction. One conversion point here rather than a cast at each of the six join sites.
    var transferKey: String { String(id) }
}

extension PoolBalance {
    /// MOB-1496 (W-D): the migratable portion of this pool's balance — every component of
    /// `total()` EXCEPT `lockedValue`. A locked residual (the "Lock balance" choice at migration
    /// Complete) has already been deliberately taken out of migration, so `orchardBalanceToMigrate`/
    /// `reconcileOrchardBalance` must not count it toward "more to migrate" — unlike `total()`,
    /// which correctly keeps locked funds in the account's overall balance.
    var unlockedForMigration: Zatoshi {
        spendableValue + changePendingConfirmation + valuePendingSpendability
    }
}

extension MigrationManagerClient: DependencyKey {
    static let liveValue: MigrationManagerClient = Self.live()

    static func live() -> Self {
        let impl = MigrationManagerImpl()

        return MigrationManagerClient(
            bannerVariant: { accountUUID in await impl.bannerVariant(accountUUID: accountUUID) },
            reentryRoute: { await impl.reentryRoute() },
            isIronwoodActivated: { impl.isIronwoodActivated() },
            orchardBalanceToMigrate: { accountUUID in await impl.orchardBalanceToMigrate(accountUUID: accountUUID) },
            migrationSummary: { accountUUID in await impl.migrationSummary(accountUUID: accountUUID) },
            migrationTransfers: { accountUUID in await impl.migrationTransfers(accountUUID: accountUUID) },
            recordCommittedSchedule: { accountUUID, schedule in
                await impl.recordCommittedSchedule(accountUUID: accountUUID, schedule: schedule)
            },
            recordTransferBroadcast: { accountUUID, result in
                await impl.recordTransferBroadcast(accountUUID: accountUUID, result: result)
            },
            lockMigrationDust: { try await impl.lockMigrationDust(accountUUID: $0) },
            isMigrationDustLocked: { await impl.isMigrationDustLocked(accountUUID: $0) },
            migrationLockedAmount: { await impl.migrationLockedAmount(accountUUID: $0) },
            migrationRoundContext: { await impl.migrationRoundContext(accountUUID: $0) },
            migrationPreparationCount: { await impl.migrationPreparationCount(accountUUID: $0) },
            migrationPreparationRows: { await impl.migrationPreparationRows(accountUUID: $0) },
            migrationPrepareBalanceRows: { await impl.migrationPrepareBalanceRows(accountUUID: $0) },
            advance: { await impl.advance(phase: $0) },
            visitKind: { await impl.visitKind() },
            runProveSweep: { accountUUID, instruction, maxProofs in
                await impl.runProveSweep(accountUUID: accountUUID, instruction: instruction, maxProofs: maxProofs)
            },
            runBroadcastSession: { accountUUID, instruction, isPreparation in
                await impl.runBroadcastSession(
                    accountUUID: accountUUID,
                    instruction: instruction,
                    vettedPreparationDelivery: isPreparation
                )
            },
            migrationChainClock: { await impl.migrationChainClock(accountUUID: $0) },
            stateEvents: { accountUUID in impl.stateEvents(accountUUID: accountUUID) },
            migrationSnapshotEvents: { accountUUID in impl.migrationSnapshotEvents(accountUUID: accountUUID) },
            currentMigrationSnapshot: { accountUUID in impl.currentMigrationSnapshot(accountUUID: accountUUID) },
            refreshMigrationSnapshot: { accountUUID in impl.refreshMigrationSnapshot(accountUUID: accountUUID) },
            migrationMode: { impl.migrationMode(accountUUID: $0) },
            setMigrationMode: { impl.setMigrationMode(accountUUID: $0, mode: $1) },
            migrationNetworkOptions: { accountUUID in await impl.migrationNetworkOptions(accountUUID: accountUUID) },
            formNetworkSnapshot: { accountUUID in await impl.formNetworkSnapshot(accountUUID: accountUUID) },
            networkSnapshot: { accountUUID in await impl.networkSnapshot(accountUUID: accountUUID) },
            confirmProvisionalTorChoice: { accountUUID, useTor in
                impl.confirmProvisionalTorChoice(accountUUID: accountUUID, useTor: useTor)
            },
            markNetworkSnapshotCommitted: { accountUUID in impl.markNetworkSnapshotCommitted(accountUUID: accountUUID) },
            clearProvisionalNetworkSnapshot: { accountUUID in impl.clearProvisionalNetworkSnapshot(accountUUID: accountUUID) },
            activeNetworkSnapshots: { impl.activeNetworkSnapshots() },
            routeBroadcastFailure: { accountUUID, failureClass in
                await impl.routeBroadcastFailure(accountUUID: accountUUID, failureClass: failureClass)
            },
            isMigrationTorHoldActive: { accountUUID in impl.isTorHoldActive(accountUUID: accountUUID) },
            isMigrationSessionVerdictKnown: { impl.isMigrationSessionVerdictKnown() },
            migrationViewSnapshot: { accountUUID in await impl.migrationViewSnapshot(accountUUID: accountUUID) },
            overrideTorForRun: { accountUUID, useTor in
                impl.overrideTorForRun(accountUUID: accountUUID, useTor: useTor)
            },
            resolveMigrationTorPrompt: { accountUUID in
                await impl.resolveTorPrompt(accountUUID: accountUUID)
            },
            overrideBroadcastEndpointToSyncServer: { accountUUID in
                await impl.overrideBroadcastEndpointToSyncServer(accountUUID: accountUUID)
            },
            isSyncServerIdentityCustom: { impl.isSyncServerIdentityCustom() },
            setNetworkPrivacyOptions: { impl.setNetworkPrivacyOptions(useTor: $0) },
            isCompleteAcknowledged: { accountUUID in impl.isCompleteAcknowledged(accountUUID: accountUUID) },
            acknowledgeComplete: { accountUUID in await impl.acknowledgeComplete(accountUUID: accountUUID) },
            isMigrationRemainderPending: { accountUUID in impl.isMigrationRemainderPending(accountUUID: accountUUID) },
            setMigrationFlowPresented: { accountUUID, isPresented in
                impl.setMigrationFlowPresented(accountUUID: accountUUID, isPresented: isPresented)
            },
            recordSyncCompleted: { impl.recordSyncCompleted() },
            migrationSyncGateFeed: { impl.migrationSyncGateFeed() },
            refreshMigrationSyncGate: { await impl.refreshMigrationSyncGate() },
            armNextWindowNotifications: { await impl.armNextWindowNotifications(accountUUID: $0) },
            markRunCancelledByUser: { accountUUID in await impl.markRunCancelledByUser(accountUUID: accountUUID) },
            reconcile: { await impl.reconcile() },
            clearAbandonedNetworkSnapshot: { accountUUID in await impl.clearAbandonedNetworkSnapshot(accountUUID: accountUUID) },
            wipeAllMigrationState: { await impl.wipeAllMigrationState() },
            resetPersistedFlags: { impl.resetPersistedFlags() }
        )
    }
}

/// R8-T3 (#18): a fair (FIFO) async mutex serializing `MigrationManagerImpl`'s mutating passes —
/// `reconcile`, `recordCommittedSchedule`, `acknowledgeComplete`, `clearAbandonedNetworkSnapshot` —
/// so a read-decide-clear span (e.g. `reconcile` observing a stale `.notStarted` state beside a
/// persisted schedule) can never interleave with a concurrent commit (`recordCommittedSchedule`
/// racing in from the no-split commit lane, which deliberately doesn't stop sync while it runs).
/// Mirrors the shape of the repo's existing FIFO-mutex-actor precedent,
/// `Dependencies/TransactionGuard/TransactionGuard.swift` — but is its OWN instance, never
/// `@Dependency(\.transactionGuard)`: `TransactionGuard` is non-reentrant (nesting it would risk
/// exactly the deadlock its own doc warns against), and it would be serializing a disjoint set of
/// operations anyway (submission-vs-switch exclusivity, not this class's storage-mutating passes).
/// MOB-1497 (R9-T6): `MigrationManagerImpl` no longer holds a `transactionGuard` dependency at all
/// — see `MigrationManagerImpl.migrationNetworkOptions`'s doc.
///
/// Deliberately simpler than `TransactionGuard`: `run(_:)` is non-throwing (every operation it
/// wraps already is) and not cancellation-aware — the wrapped bodies are fast in-memory/
/// `UserDefaults` work, never long-running network I/O, so a parked waiter's wait is bounded and
/// `TransactionGuard`'s cancellation-safety plumbing (built for ITS network-bound use case) isn't
/// worth mirroring here too.
actor MigrationManagerSerialExecutor {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var isBusy = false
    private var waiters: [Waiter] = []

    /// Runs `body` with exclusive access against every other `run(_:)` call on this SAME instance —
    /// FIFO: a caller that arrives while busy is queued and woken in arrival order. `nonisolated` so
    /// `body` executes in the CALLER's context (never hopping onto this actor) — only the
    /// acquire/release bookkeeping below is actor-isolated, mirroring the split between the
    /// `TransactionGuard` actor and its non-isolated `TransactionGuardClient.withSubmission` wrapper.
    nonisolated func run<T>(_ body: () async -> T) async -> T {
        await acquire()
        let result = await body()
        await release()
        return result
    }

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(Waiter(id: id, continuation: continuation))
        }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            let next = waiters.removeFirst()
            next.continuation.resume() // `isBusy` stays true — ownership transfers to the resumed waiter.
        }
    }
}

/// MOB-1466: state for `advance(phase:)`'s single-flight latch — see
/// `MigrationManagerImpl.advanceLatch`'s doc for why it is a stored property on that class rather
/// than an actor, and `MigrationStepDriver.swift` for the acquire/release functions that hold this
/// lock.
///
/// FIFO queue of PARKED `.beforeSync`/`.afterSync` callers, mirroring
/// ../zcash-swift-wallet-sdk's `OrchardMigration.serializedBroadcastFlow`'s own
/// `isBroadcastFlowInFlight`/`broadcastFlowWaiters` pair — adjusted for a lock rather than an
/// actor's isolation: an actor's isolation already serializes every access to those two vars by
/// construction, so the SAME pair guarded by an explicit lock takes its place here. `.tick` callers
/// never enter `waiters` at all — they try the lock once (`tryAcquireAdvanceLatch`) and yield
/// (`.skipped`) rather than park, so this queue only ever holds callers that are GOING to run.
struct MigrationAdvanceLatchState {
    var isBusy = false
    var waiters: [CheckedContinuation<Void, Never>] = []
}

/// R0: the per-open-lane spent-credit record — see `MigrationManagerImpl.openLaneCredits` for the
/// law it enforces. Each slot holds the session ordinal whose credit that lane has consumed;
/// `nil` means the lane has not driven in any session yet. `.tick` deliberately has no slot here:
/// it is not an open lane (see `MigrationStepPlan`'s "THE THIRD PHASE") and is governed by the
/// mode belt, the privacy buffer, and the engine's own schedule instead.
struct MigrationOpenLaneCredits {
    var beforeSyncSpentSession: Int?
    var afterSyncSpentSession: Int?
}

/// Composes `sdkSynchronizer` + `MigrationGateStorage` and owns the per-account `stateEvents`
/// subjects. `@unchecked Sendable`: the only mutable state is `gateStorage`'s own
/// `OSAllocatedUnfairLock`-protected storage, the `serialExecutor` actor, the `advanceLatch` lock,
/// plus the Combine subjects below, all of which are safe to share across isolation domains.
final class MigrationManagerImpl: @unchecked Sendable {
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
    // MOB-1497 (R7): the uniform-random broadcast-endpoint pick's test-controllable randomness seam
    // — see `MigrationRandomnessInterface.swift`'s doc for why this exists instead of a raw
    // `RandomNumberGenerator`.
    @Dependency(\.migrationRandomness) var migrationRandomness

    @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
    @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
    @Dependency(\.userNotifications) var userNotifications

    // The three seams `MigrationStepDriver` needs to discharge the engine's `.rebuild` step without
    // the user: deriving a software account's spending key so the engine can re-sign the rebuilt
    // rows in place. Exactly the trio `MigrationSpendingKeyDerivation.deriveUSK` takes, and exactly
    // what the Recovery screen's button already uses — the driver runs the same code, just without
    // requiring the user to find the screen first. `exportWallet()` is a plain keychain read on iOS
    // (no biometric prompt), which is what makes this safe to do on an ordinary app-open.
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.derivationTool) var derivationTool

    enum Constants {
        /// PHASE 4 (D9): how far AHEAD of a send window the `timeToSync` poke fires. Long enough
        /// that a cold wallet can reach the tip before due-ness is computed against it, short
        /// enough that the ask still reads as related to the window it precedes.
        static let timeToSyncLead: TimeInterval = 2 * 60 * 60
    }

    /// The migration lane's log tag. Deliberately NOT the word "migration": that string appears in
    /// enough surrounding context (file names, paths, type names) that filtering a console on it
    /// selects far more than this lane — which cost a tester a testing session. `[MIG]` collides
    /// with nothing. Every migration log line in the app starts with it.
    /// MOB-1466: the session-stamped prefix — `[MIG s3 +12.34s]`. Computed rather than constant so
    /// EVERY pre-existing `LoggerProxy.event("\(Self.logTag) …")` line in this file gains its
    /// session ordinal and elapsed time without a single call site changing. See `MigrationTrace`.
    static var logTag: String { MigrationTrace.tag() }

    let gateStorage: MigrationGateStorage
    /// MOB-1496 (W2): per-account persisted committed schedule — see `MigrationScheduleStorage`.
    let scheduleStorage: MigrationScheduleStorage
    /// MOB-1496 (W4): per-account persisted atomic network snapshot — see `MigrationSnapshotStorage`.
    let snapshotStorage: MigrationSnapshotStorage
    /// R8-T3 (#18): serializes `reconcile`/`recordCommittedSchedule`/`acknowledgeComplete`/
    /// `clearAbandonedNetworkSnapshot` — see `MigrationManagerSerialExecutor`'s doc.
    let serialExecutor = MigrationManagerSerialExecutor()

    /// MOB-1497 (R7-T3): per-account persisted failure-routing state (had-broadcast flag + R16
    /// episode set) — see `MigrationFailureRoutingStorage`.
    let failureRoutingStorage: MigrationFailureRoutingStorage

    /// R0 seam: where `advance(phase:)` reads the live session ordinal. Production wiring keeps
    /// the default (the real `MigrationTrace`); driver unit tests pin a constant instead, because
    /// the trace is PROCESS-GLOBAL and parallel suites exercise Root reducers whose production
    /// paths begin/end sessions underneath any test that reads it — the same churn that forced
    /// retry-hardening onto the C6-1 latch test and an age-based (not session-based) M5 cache
    /// gate. The seam makes the credit logic deterministic under test without weakening the
    /// production read.
    let sessionOrdinalProvider: @Sendable () -> Int?

    /// Internal (not private) with injectable storage so unit tests can exercise the real
    /// `reconcile()` against a scoped `UserDefaults` suite.
    init(
        gateStorage: MigrationGateStorage = MigrationGateStorage(),
        scheduleStorage: MigrationScheduleStorage = MigrationScheduleStorage(),
        snapshotStorage: MigrationSnapshotStorage = MigrationSnapshotStorage(),
        failureRoutingStorage: MigrationFailureRoutingStorage = MigrationFailureRoutingStorage(),
        sessionOrdinalProvider: @escaping @Sendable () -> Int? = { MigrationTrace.currentSessionOrdinal }
    ) {
        self.gateStorage = gateStorage
        self.scheduleStorage = scheduleStorage
        self.snapshotStorage = snapshotStorage
        self.failureRoutingStorage = failureRoutingStorage
        self.sessionOrdinalProvider = sessionOrdinalProvider
    }

    /// MOB-1496: one `CurrentValueSubject` per account `stateEvents` has ever been asked about,
    /// seeded `.notStarted`. `reconcile()` (and, indirectly, every store that calls it after a
    /// completed migration op) is the only writer; it emits only when a re-read's value differs
    /// from the subject's current value.
    private let stateSubjects = OSAllocatedUnfairLock<[AccountUUID: CurrentValueSubject<MigrationState, Never>]>(initialState: [:])
    /// MOB-1496 (W2 emit-fix): last-pushed `orchardBalanceToMigrate(accountUUID) > 0` per account,
    /// held beside `stateSubjects` (whose `CurrentValueSubject.value` already tracks the last-
    /// pushed `MigrationState` — the subject itself still only ever carries `MigrationState`).
    /// `reconcile()` pushes into a subject whenever EITHER component changed since the last push.
    /// An account with no entry yet defaults to `false`, pairing with the subject's own
    /// `.notStarted` seed: a first real reconcile reading `.notStarted`/no-balance pushes nothing
    /// (value unchanged).
    private let lastPushedHasBalance = OSAllocatedUnfairLock<[AccountUUID: Bool]>(initialState: [:])
    /// R13 Brick 1: one `CurrentValueSubject` per account `migrationSnapshotEvents` has ever been
    /// asked about, seeded `nil` (no derivation yet). THE published channel — the full
    /// `MigrationViewSnapshot`, not `stateEvents`' coarse enum, so a subscriber renders the payload
    /// instead of answering a doorbell with its own query at its own time. Fed exclusively by
    /// `scheduleSnapshotRepublish` (coalesced, value-deduplicated); every writer edge funnels there
    /// via `pushStateIfChanged`/`pokeStateEvent`/`recordSyncCompleted`.
    private let snapshotSubjects = OSAllocatedUnfairLock<[AccountUUID: CurrentValueSubject<MigrationViewSnapshot?, Never>]>(initialState: [:])
    /// R13 Brick 1: the republish coalescer — a snapshot build is several FFI reads (measured
    /// 4.75 s quiet, 18.3 s under a sweep), so poke bursts must collapse: one build in flight per
    /// account, at most one queued behind it (`dirty`), never a pile-up.
    private let snapshotRepublishState = OSAllocatedUnfairLock<(inFlight: Set<AccountUUID>, dirty: Set<AccountUUID>)>(initialState: ([], []))
    /// A13: accounts whose broadcast is IN FLIGHT right now, in this app session
    /// (`runBroadcastSession`). Read by `bannerVariant` to raise `.transferSending`.
    ///
    /// Deliberately in-memory and NOT persisted: it describes a live submission, so a process that
    /// dies mid-broadcast must come back with it clear — a persisted flag would strand the "sending,
    /// keep the app open" banner forever, asking the user to keep alive a session that no longer
    /// exists. It is also the re-entrancy guard: a second driver call for the same account while one
    /// is running is a no-op rather than a double submit.
    private let broadcastsInFlight = OSAllocatedUnfairLock<Set<AccountUUID>>(initialState: [])

    /// GROUND_RULES D6: the transaction id the CURRENT broadcast session is actually submitting.
    ///
    /// The `.transferSending` banner used to infer its number from `first { $0.isBroadcasting }` —
    /// which names the PREVIOUS transfer whenever one is still broadcast-but-unmined while a new one
    /// submits (field: "T8 is sending..." during T9's submit). The session KNOWS the id — it logs
    /// `broadcasting migration tx N` — so it records it here and the banner renders it instead of
    /// re-guessing. Set/cleared around the submit, exactly like `broadcastsInFlight`.
    private let activeBroadcastTxIds = OSAllocatedUnfairLock<[AccountUUID: UInt32]>(initialState: [:])

    /// THE BANNER MAP (Lukas, 2026-08-06): whether the account's in-flight broadcast is a note-
    /// PREPARATION. Split/prep sends have no banner copy of their own — they wear the keep-open
    /// costume (`.preparing`), never "Transfer N is sending" — and the `.inProgress` state's
    /// sending arm needs the kind to honor that structurally rather than by unreachability.
    /// Set/cleared around the submit, exactly like `broadcastsInFlight` above.
    private let preparationBroadcastsInFlight = OSAllocatedUnfairLock<Set<AccountUUID>>(initialState: [])

    /// GROUND_RULES R3: the session ordinal whose engine verdict has been heard. The banner may not
    /// publish any migration state before the CURRENT session's first verdict — until then it shows
    /// `.checkingStatus` (Figma 5679-8225). Ordinal-keyed so a new app-open invalidates it for free.
    private let sessionVerdictOrdinal = OSAllocatedUnfairLock<Int?>(initialState: nil)

    /// MOB-1466: single-flight latch guarding the WHOLE body of `advance(phase:)` — see
    /// `MigrationStepDriver.swift`'s acquire/release functions for the mechanism, and its file
    /// header (I1-I5) for why `advance` cannot simply overlap itself. A `.tick` fires every 30s from
    /// Root's foreground loop and must never queue up behind a slower `.beforeSync`/`.afterSync`
    /// call (or behind another tick) — it yields instead (`MigrationStepVerdict.skipped`) — while an
    /// app-open's own `.beforeSync`/`.afterSync` call must never be silently dropped for arriving
    /// mid-tick, so it waits its turn (FIFO) instead.
    ///
    /// `internal` (no access modifier), not `private`: Swift's `private` is FILE-scoped, and the
    /// acquire/release functions that use this live in `MigrationStepDriver.swift`, a different
    /// file — the same reason `gateStorage`/`scheduleStorage`/`snapshotStorage` above are `let`
    /// rather than `private let`. `OSAllocatedUnfairLock`-guarded rather than an actor:
    /// `MigrationManagerImpl` is a class, not an actor, and this state must live on IT (there is no
    /// separate actor to isolate it on) — see `MigrationAdvanceLatchState`'s doc for how the
    /// resulting check-under-lock / await-continuation-outside shape mirrors
    /// ../zcash-swift-wallet-sdk's `OrchardMigration.serializedBroadcastFlow` despite the different
    /// primitive.
    let advanceLatch = OSAllocatedUnfairLock<MigrationAdvanceLatchState>(initialState: MigrationAdvanceLatchState())

    /// R0 (Lukas, 2026-08-05 — "the ground rule of all ground rules", ratifying C6-1's lesson):
    /// per-open-lane, per-session drive credits. One zodl open arms exactly ONE `.beforeSync` and
    /// ONE `.afterSync` credit; the first drive of each lane consumes it and every later
    /// same-session call yields. Stored as "the session ordinal whose credit this lane has spent"
    /// rather than a plain armed/disarmed Bool so a stale flag can never leak across opens — a new
    /// session re-arms both lanes for free by having a new ordinal.
    ///
    /// The field case that made this law (C6-1, campaign-6, on camera): Root's launch paths
    /// (cold-launch site, gate-resume retryStart, the refused-start catch) each call
    /// `.beforeSync` by convention "once per open" — an open that traversed two of them drove the
    /// engine twice, and with a due pile-up each drive is a BROADCAST: two sends 4 s apart in one
    /// session, which is a ZIP 318 violation (the engine schedules those sends APART; asking twice
    /// collapsed the spacing). `.afterSync` has the same shape available (two call sites, plus a
    /// sync edge that can re-fire within one foreground). The engine answered honestly every time;
    /// the discipline is the app's, so it lives at the one chokepoint every path shares — see
    /// `advance(phase:)`'s R0 credit gate.
    let openLaneCredits = OSAllocatedUnfairLock<MigrationOpenLaneCredits>(initialState: MigrationOpenLaneCredits())

    /// MOB-1513 (H3 guard): in-memory (never persisted — a flow being on screen doesn't survive
    /// relaunch, and shouldn't) set of accounts CURRENTLY showing a propose-consuming migration
    /// screen. `reconcile()` reads this per-account (`isMigrationFlowPresented`) to decide whether
    /// to skip `evaluateMigrationRemainder` — see that method's doc for the plan-cache hazard this
    /// closes.
    ///
    /// Armed (`setMigrationFlowPresented(_, true)`) from exactly one production site:
    /// `MigrationCoordFlowCoordinator.onAppear`'s genuine-flow-start branch (`state.path.isEmpty`).
    ///
    /// Disarmed (`setMigrationFlowPresented(_, false)`) from every production close/replace site
    /// for `Root.State.Path.migrationCoordFlow`, verified exhaustively against HEAD while
    /// implementing this guard:
    ///   - `RootCoordinator.tearDownMigrationCoordFlow` — the shared helper `.flowFinished`,
    ///     `.switchServerRequested`, and the inline teardown inside `.home(.walletAccountTapped)`
    ///     all three route through.
    ///   - `RootCoordinator`'s `.migrationCoordFlow(.path(.element(_, .sending(.delegate
    ///     (.viewTransaction)))))` case — closes `state.path` directly (the flow is already past
    ///     commit by the time this fires) WITHOUT routing through `tearDownMigrationCoordFlow`, so
    ///     it disarms independently rather than being missed.
    ///   - `RootInitialization.openMigrationCoordFlow` (the notification-tap deep link) —
    ///     wholesale-REPLACES `migrationCoordFlowState` with a fresh `.initial`, discarding
    ///     whatever was recorded, and can fire while the flow is ALREADY open (R8-T6 already
    ///     established this exact hazard class for the send-wait-hold flag — see
    ///     `notificationTapTeardownReleasesLiveSendWaitHoldAndUnfencesRetryStart`'s doc); disarms
    ///     the OLD recorded account here, before the reset discards the only record of which
    ///     account it was armed for.
    ///
    /// Every one of these reads back `MigrationCoordFlow.State.presentedMigrationFlowAccountUUID`
    /// — the account THIS flow instance recorded as its owner at open — rather than whatever
    /// `Root.State.selectedWalletAccount` happens to read at close time, so an account switch
    /// racing the close can never disarm (or arm) the wrong account's signal. Mirrors
    /// `MigrationCoordFlow.State.pendingKeystoneSigningAccountUUID`'s identical "record the owner,
    /// don't trust the account selected at close time" precedent.
    private let presentedFlowAccountUUIDs = OSAllocatedUnfairLock<Set<AccountUUID>>(initialState: [])

    /// R13 Brick 2b: the accessor is now a WINDOW onto the published snapshot — the ladder position
    /// is decided inside the loader (`bannerArm`, called from `migrationViewSnapshot`'s one pass),
    /// so a banner answer and the rows it describes can never come from different moments. Reading
    /// the published value is free, which also retires the double-derivation Brick 2 introduced
    /// transitionally (a snapshot emission triggered a reevaluation whose pull re-derived).
    ///
    /// The pre-2b machinery this replaces: `bannerCache` + its starvation serve (the PUBLISHED
    /// value is the cache now — during a sweep the coalesced build lands late and this keeps
    /// answering the last published truth, same behavior, one mechanism) and the
    /// `bannerTransferRows` mirror derivation (THE rows are the bundle's).
    ///
    /// First ask of a launch (no build published yet): build once THROUGH the loader and PUBLISH
    /// the result, so this answer and the channel's first value are the same object — the banner
    /// walk and a later-subscribing screen cannot disagree about what the first verdict was.
    func bannerVariant(accountUUID: AccountUUID?) async -> MigrationBannerVariant? {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else {
            LoggerProxy.event("\(Self.logTag) no banner: no account selected")
            return nil
        }
        if let published = snapshotSubjects.withLock({ $0[resolvedAccountUUID]?.value }) ?? nil {
            return published.banner
        }
        let snapshot = await migrationViewSnapshot(accountUUID: resolvedAccountUUID)
        publishSnapshot(snapshot, for: resolvedAccountUUID)
        return snapshot.banner
    }

    /// R13 Brick 2b: THE banner arm of the loader — called only from `migrationViewSnapshot`'s one
    /// pass, with the pass's own rows, preparations and balances. The gates and reads are the old
    /// `bannerVariantUntimed`'s, verbatim; what died is the mirror row derivation (`transfers`/
    /// `preparations` arrive as parameters — the SAME lists every other snapshot field describes,
    /// R2's "one position, one value" finally executable) and the separate full-wallet balance
    /// read (the pass's one `getAccountsBalances` serves it).
    private func bannerArm(
        resolvedAccountUUID: AccountUUID,
        transfers: [MigrationTransferRow],
        preparations: [MigrationTransferRow],
        balances: [AccountUUID: AccountBalance]?
    ) async -> MigrationBannerVariant? {
        // MOB-1513 (B2 fix wave): pre-activation there is no migration banner to derive — the pure
        // `MigrationDerivations.bannerVariant` already returns nil for `isIronwoodActivated == false`
        // (checked ahead of every row). Short-circuit BEFORE the five async reads below (rust
        // `migrationState`, progress, overdue, orchard balance, round context) rather than issuing
        // them and discarding the result: each is a pure read, so moving the exit earlier only saves
        // work and the return value is unchanged. Callers consume the returned variant only, never a
        // side effect of those reads.
        guard isIronwoodActivated() else {
            LoggerProxy.event(
                "\(Self.logTag) no banner: ironwood NOT activated — tip \(sdkSynchronizer.latestState().latestBlockHeight)"
                + ", activation \(zcashSDKEnvironment.ironwoodActivationHeight())"
            )
            return nil
        }
        guard let rawState = await migrationState(accountUUID: resolvedAccountUUID) else {
            // `migrationState` has already logged WHY it could not answer.
            return nil
        }

        // GOAL 1 — DO NOT OFFER A MIGRATION ON A WALLET THAT IS NOT CAUGHT UP.
        //
        // The gate above is ACTIVATION (is the chain past NU6.3), not FRESHNESS. Those are
        // different questions and only the first was ever asked. A wallet that has not been opened
        // for six months answers "activated: yes" the moment it learns the tip, while its Orchard
        // balance is still whatever it was six months ago — so the app would offer to migrate a
        // number it has not verified, and size a plan from it.
        //
        // Every test so far ran immediately after a restore, where the wallet is caught up by
        // construction, which is exactly why this never showed.
        //
        // Scoped to `.notStarted` DELIBERATELY. A run already in flight must keep rendering through
        // sync gaps — its plan was committed against a verified balance, and a broadcast session
        // deliberately does not sync at all (ZIP 318), so demanding `.upToDate` mid-run would blank
        // the banner exactly when the user most needs it.
        if case .notStarted = rawState, !isCaughtUpForMigrationOffer() {
            let syncState = sdkSynchronizer.latestState()
            MigrationTrace.event(
                "offer HELD — wallet not caught up"
                + " · status \(syncState.syncStatus)"
                + " · height \(syncState.latestBlockHeight)"
            )
            return nil
        }

        async let progressTask = migrationProgress(accountUUID: resolvedAccountUUID)
        async let hasOverdueTask = hasOverdueMigrationTransfers(accountUUID: resolvedAccountUUID)
        async let clockTask = chainClock(accountUUID: resolvedAccountUUID)

        let progress = await progressTask
        let hasOverdue = await hasOverdueTask
        let clock = await clockTask
        // R13 Brick 2b: the pass's one balances read serves the offer amount — the same
        // expression `orchardBalanceToMigrate` computes, without a second full-wallet read.
        let balance = balances?[resolvedAccountUUID]?.orchardBalance.unlockedForMigration ?? Zatoshi.zero

        let state = rawState
        // MOB-1511 (W2): the multi-round context for the round-aware banner arms.
        let roundContext = await migrationRoundContext(accountUUID: resolvedAccountUUID)

        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: isIronwoodActivated(),
            state: state,
            orchardBalance: balance,
            isCompleteAcknowledged: gateStorage.isCompleteAcknowledged(for: resolvedAccountUUID),
            // MOB-1496: nil (never evaluated) reads as `false` here, same "not known to be
            // pending" convention `MigrationManagerImpl.isMigrationRemainderPending` uses.
            isMigrationRemainderPending: gateStorage.remainderPending(for: resolvedAccountUUID) ?? false,
            transferRows: transfers,
            preparationRows: preparations,
            // A13: purely in-session — see `broadcastsInFlight`'s doc. Read last, after every async
            // read above has settled, so the answer is as close to "now" as this function gets.
            // MOB-1466: now only an ACCELERATOR — the durable `.broadcast` row is checked first.
            isBroadcastInFlight: broadcastsInFlight.withLock { $0.contains(resolvedAccountUUID) },
            // THE BANNER MAP: the in-flight broadcast's kind — a prep wears keep-open, never
            // "Transfer N is sending".
            isPreparationBroadcastInFlight: preparationBroadcastsInFlight.withLock { $0.contains(resolvedAccountUUID) },
            activeBroadcastTxId: activeBroadcastTxIds.withLock { $0[resolvedAccountUUID] },
            round: roundContext.round,
            totalRounds: roundContext.totalRounds
        )

        // The decision, always, with the two inputs that explain a surprising one. "No banner" was
        // silent through four separate exits before the 07-31 test session, and a silent decision is
        // untestable: a tester who sees nothing cannot tell "correctly quiet" from "broken".
        //
        // MOB-1466: routed through `MigrationTrace.banner` rather than logged raw, so this prints on
        // CHANGE only, carries how long the value it replaces was on screen, and flags anything that
        // held for less than a readable moment. `bannerVariant` is recomputed on every poke and on
        // every screen appearance — forty identical lines used to be indistinguishable from forty
        // flickers, and it is the flickers that get reported as bugs.
        MigrationTrace.banner(
            variant,
            why: bannerReason(
                state: state,
                rows: transfers,
                preparations: preparations,
                hasOverdue: hasOverdue,
                isBroadcastInFlight: broadcastsInFlight.withLock { $0.contains(resolvedAccountUUID) }
            ),
            detail: "state \(state), orchard \(balance.decimalString())"
        )
        MigrationTrace.rows(transfers: transfers, preparations: preparations)

        return variant
    }

    /// R7 final review, Important-1 (spec §G): per-account read of the persisted Tor-hold indicator
    /// — see `MigrationFailureRoutingStorage.torHoldActive`'s doc. Backs `MigrationManagerClient
    /// .isMigrationTorHoldActive`, consumed by `MigrationStatusStore`'s resume-presentation footer
    /// (and `MigrationCoordFlowCoordinator`'s twin re-entry hydration).
    func isTorHoldActive(accountUUID: AccountUUID?) -> Bool {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return false }
        return failureRoutingStorage.torHoldActive(for: resolvedAccountUUID)
    }



    /// R8-T3 (#23): same one-read-each treatment as `bannerVariant` above — the pre-fix version
    /// read `progress` up to 2x (once directly
    /// here, once again inside `isNextTransferDue`). Unlike `bannerVariant`'s `hasInvalid`,
    /// `reentryRoute`'s OWN `hasInvalid` read stays: `MigrationDerivations.reentryRoute` genuinely
    /// branches on it (row 1, `.recovery`).
    func reentryRoute() async -> MigrationReentryRoute {
        guard let accountUUID = selectedWalletAccount?.id else { return MigrationReentryRoute.entry }

        // MOB-1466 — THE THIRD OCCUPANT. The actor-starvation guard was added to `bannerVariant`
        // (:446) and `migrationTransfers` (:730) and the class was declared closed. It was not:
        // this function is the one behind the smart banner's button, and it awaits SIX actor-bound
        // reads, every one of which queues behind an in-flight prove sweep. The field caught it
        // exactly:
        //
        //     [MIG s3 +2.42s]  BANNER -> preparing
        //     [MIG s3 +47.36s] prove sweep: proved 2 transaction(s)
        //     [MIG s3 +47.38s] ROUTE: (first) -> statusProgress     <- 20 ms after the sweep ended
        //
        // A 45-second sweep is a 45-second blank screen with a spinner. In the same log the fast
        // session (s2, sweep 2.4 s) routed at +3.24 s. The route time IS the sweep time.
        //
        // WHY THIS STILL NEEDS A SHORT-CIRCUIT WHEN BANNER/ROWS NO LONGER DO. Q2-1 moved the six
        // hot migration reads onto read-only DB connections, so `bannerVariant` and
        // `migrationTransfers` now simply derive fresh every time — there is no cache left to serve
        // stale, because there is no slow read left to bridge. `migrationAdvanceStep` did not move:
        // this function awaits it directly below, and `migrationState` awaits it again internally,
        // so a route that always fell through would still queue behind an in-flight prove sweep on
        // that one read. A route is NAVIGATION, not content — a stale route opens the wrong screen
        // (`.statusResume` offers "Send now"), and a wrong action is worse than a slow one, so this
        // is the one place a still-serialized read gets a short-circuit instead of a wait.
        //
        // So: fall back to the READ-ONLY list instead. `.statusProgress` shows the transfer
        // timeline and offers no action the engine could refuse, so landing there for a moment and
        // being moved on the coordinator's next re-entry pass costs nothing. Gated on a committed
        // schedule existing, which is exactly "a run exists" — without it a not-started wallet would
        // be sent to a progress screen for a migration it does not have.
        if isMigrationWorkInFlight, scheduleStorage.committedSchedule(for: accountUUID) != nil {
            MigrationTrace.event(
                "route SHORT-CIRCUIT -> statusProgress — migration work in flight, not blocking the UI"
            )
            return MigrationReentryRoute.statusProgress
        }

        async let rawStateTask = migrationState(accountUUID: accountUUID)
        async let progressTask = migrationProgress(accountUUID: accountUUID)
        async let hasInvalidTask = hasInvalidMigrationTransfers(accountUUID: accountUUID)
        async let hasOverdueTask = hasOverdueMigrationTransfers(accountUUID: accountUUID)
        async let clockTask = chainClock(accountUUID: accountUUID)
        // The engine's own answer, read alongside the rest rather than after them — see
        // `MigrationDerivations.reentryRoute`'s doc for why it now outranks the clock. A failed read
        // contributes `nil`, which offers no action at all: the failure mode of this input is a
        // quieter screen, never a button the engine will refuse.
        async let advanceStepTask = try? sdkSynchronizer.migrationAdvanceStep(accountUUID)

        let rawState = await rawStateTask ?? MigrationState.notStarted
        let progress = await progressTask
        let hasInvalid = await hasInvalidTask
        let hasOverdue = await hasOverdueTask
        let clock = await clockTask
        let advanceStep = (await advanceStepTask)?.step

        let state = rawState

        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: isIronwoodActivated(),
            state: state,
            advanceStep: advanceStep,
            hasInvalid: hasInvalid,
            hasOverdue: hasOverdue,
            isCompleteAcknowledged: gateStorage.isCompleteAcknowledged(for: accountUUID),
            progress: progress
        )

        // Which screen a banner tap opens, and the inputs that decided it. Added 07-31 after a
        // tester saw the Resume screen (Reschedule / Send now) and then, across a restart with no
        // action in between, the Progress screen (Got it) — with no way for either of us to tell
        // whether the STATE had changed or the ROUTING was wrong. Deciding which is not the
        // tester's job; the app should say. `state` and `hasOverdue` are the pair that flips this
        // route, so they are named rather than left to be inferred.
        // MOB-1466: on CHANGE only, with dwell — see `MigrationTrace.route`. A route that moves
        // while the banner's words stay put means the same sentence now opens a different screen,
        // which the user experiences as the app having lied to them.
        MigrationTrace.route(
            route,
            detail: "state \(state), hasOverdue \(hasOverdue), hasInvalid \(hasInvalid), activated \(isIronwoodActivated())"
        )

        return route
    }

    /// THE SINGLE DERIVATION — see `MigrationViewSnapshot`.
    ///
    /// Rows, both pool balances and the done-total are read in one pass, so every observer sees the
    /// same snapshot. Pool balances and progress rows remain independent SDK facts; this function
    /// deliberately does not reconcile one from the other.
    func migrationViewSnapshot(accountUUID: AccountUUID?) async -> MigrationViewSnapshot {
        guard let resolved = accountUUID ?? selectedWalletAccount?.id else {
            return MigrationViewSnapshot.empty
        }
        // R13 Brick 1: the BUNDLE, not just rows. Unstamped rows are fine here: the builder reads
        // `status`/`amount`, which the submit stamp never touches — the snapshot's own
        // `isSubmitting` field is taken separately, last, below.
        let derivation = await transferDerivation(accountUUID: resolved)
        let rows = derivation.rows
        let balances = try? await sdkSynchronizer.getAccountsBalances()
        let done = rows.filter { $0.status == MigrationTransferRow.Status.sent }
        let preparations = await migrationPreparationRows(accountUUID: resolved) ?? []
        // R13 Brick 2: the summary joins the pass (the status screen and the coordinator's
        // hydrations used to fetch it separately, at separate moments). Computed fresh — the
        // builder's own starvation stance is the coalesced republisher: during a sweep the build
        // simply lands late, and the UI keeps the last PUBLISHED value with its age label rather
        // than a mixed-clock blend.
        let summary = await migrationSummaryComputing(accountUUID: resolved)
        // R13 Brick 2b: the banner's ladder position, decided from THIS pass's rows, preparations
        // and balances — the banner's own mirror derivation (the last second-pass truth reader) is
        // gone. `bannerArm` keeps the old gates, reads and traces verbatim.
        let banner = await bannerArm(
            resolvedAccountUUID: resolved,
            transfers: rows,
            preparations: preparations,
            balances: balances
        )

        // R9 (final): TRACE-ONLY reconciliation figure — Σ of all plan amounts, for the POOLS line
        // (plan vs green vs pools). Never rendered: bubbles labelled with pool names show the
        // wallet's real balances, never a derived sum. nil when any amount is unknown (W1
        // fallback).
        let planTotal: Zatoshi? = rows.isEmpty || rows.contains { $0.amount == nil }
            ? nil
            : rows.reduce(Zatoshi.zero) { $0 + ($1.amount ?? Zatoshi.zero) }

        // The wallet summary is the only source of pool accounting. With the pinned SDK, proving
        // only records migration state and advisory-locks inputs; the wallet transaction is stored
        // at broadcast. Migration engine states describe progress and must not rewrite balances.
        let sdkBalance = balances?[resolved]

        let snapshot = MigrationViewSnapshot(
            // Use the complete pool balance here, including proposal-scoped advisory locks. The
            // `unlockedForMigration` view remains correct for completion/gating, but using it for
            // display made proved transactions disappear from every pool until broadcast.
            orchardRemaining: sdkBalance?.orchardBalance.total() ?? .zero,
            // The wallet's own destination-pool figure, never inferred from transfer status.
            ironwoodHeld: sdkBalance?.ironwoodBalance.total() ?? .zero,
            movedByDoneTransfers: done.reduce(Zatoshi.zero) { $0 + ($1.amount ?? Zatoshi.zero) },
            doneTransfers: done.count,
            totalTransfers: rows.count,
            // R13 Brick 2: stamped at BUILD time (not at an accessor's exit) — the broadcast
            // session republishes at both edges, so the published rows' "Sending now" turns on and
            // off with the submit itself.
            transfers: stampingActiveSubmit(rows, accountUUID: resolved),
            summary: summary,
            banner: banner,
            preparations: preparations,
            planTotal: planTotal,
            isTorHoldActive: failureRoutingStorage.torHoldActive(for: resolved),
            needsTorFirstRunChoice: failureRoutingStorage.pendingTorPrompt(for: resolved),
            // The in-session "a submit call is open right now" fact, taken LAST so it is as fresh as
            // the snapshot claims to be. Same flag the banner's split arm reads, so the banner's
            // "keep Zodl open" and the timeline's spinner turn on and off together.
            isSubmitting: broadcastsInFlight.withLock { $0.contains(resolved) },
            sessionOrdinal: MigrationTrace.currentSessionOrdinal,
        )
        // Goal #6: both header figures, every derivation, so the claim can be READ rather than
        // eyeballed on a device. `settled false` is the destination trailing the checkmarks and is
        // normal — see `MigrationViewSnapshot.isPoolFlowSettled`.
        MigrationTrace.event(
            "POOLS: orchard \(snapshot.orchardRemaining.decimalString())"
            + " → ironwood \(snapshot.ironwoodHeld.decimalString())"
            + " · done \(snapshot.doneTransfers)/\(snapshot.totalTransfers)"
            + " = \(snapshot.movedByDoneTransfers.decimalString())"
            + " · settled \(snapshot.isPoolFlowSettled)"
            + " · plan \(planTotal.map { $0.decimalString() } ?? "?")"
            + " · splits \(preparations.count)"
            + (snapshot.isSubmitting ? " · SUBMITTING" : "")
        )
        return snapshot
    }

    func orchardBalanceToMigrate(accountUUID: AccountUUID?) async -> Zatoshi {
        guard let accountUUID else { return .zero }

        guard let balances = try? await sdkSynchronizer.getAccountsBalances(),
              let balance = balances[accountUUID] else {
            return .zero
        }

        // MOB-1496 (W-D): excludes `lockedValue` — a locked residual (the "Lock balance" choice at
        // migration Complete) has already been deliberately taken out of migration, so it must not
        // inflate the Migration Entry headline or re-trigger the `.required` banner on re-entry.
        // See `PoolBalance.unlockedForMigration`'s doc.
        return balance.orchardBalance.unlockedForMigration
    }

    /// MOB-1496 W2: derives from the persisted committed schedule (`MigrationScheduleStorage`) +
    /// live reads, via `MigrationDerivations.summary`. No payload persisted (fresh install mid-run,
    /// or pre-commit — the SDK retains no proposal list to derive from either) falls back to the W1
    /// progress-only approximation, kept verbatim below rather than deleted.
    ///
    /// Q2-1: computes fresh on every call — the SDK now serves this read from a read-only
    /// connection in milliseconds, so the serve-stale bridge this used to need is retired.
    func migrationSummary(accountUUID: AccountUUID?) async -> MigrationSummary {
        await migrationSummaryComputing(accountUUID: accountUUID)
    }

    private func migrationSummaryComputing(accountUUID: AccountUUID?) async -> MigrationSummary {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return MigrationSummary.zero }

        guard let committedSchedule = scheduleStorage.committedSchedule(for: resolvedAccountUUID) else {
            // [MOB-1513] W1 fallback: no persisted payload yet — everything derivable comes from
            // `getMigrationProgress` alone (counts and the remaining Orchard value, mapped onto
            // `dust`). `transferred`/`estimatedDurationHours` need per-transfer amounts and the
            // schedule's own duration estimate, neither recoverable from progress alone, so they
            // read `nil` — never a placeholder `0`. On a missing account or any SDK-read error,
            // `.zero` (whose own `transferred`/`estimatedDurationHours` are `nil` too).
            guard let progress = await migrationProgress(accountUUID: resolvedAccountUUID) else { return MigrationSummary.zero }

            return MigrationSummary(
                transferred: nil,
                dust: progress.remainingOrchard,
                transfersSent: progress.completedTransfers,
                transfersTotal: progress.totalTransfers,
                estimatedDurationHours: nil
            )
        }

        let state = await migrationState(accountUUID: resolvedAccountUUID) ?? MigrationState.notStarted
        // Flattens `Zatoshi??` (threw, or genuinely no residual) down to `nil` either way — both
        // read as "not available" per the derivation's own fallback precedence.
        let residual = (try? await sdkSynchronizer.residualAfterMigration(resolvedAccountUUID)) ?? nil
        let progress = await migrationProgress(accountUUID: resolvedAccountUUID)
        // The `.complete` fallback — see the `dust` derivation. Read unconditionally rather than
        // only at `.complete`: it is the same live balance read the banner already does on every
        // derivation, and branching on state here would just make the two disagree.
        let orchardBalance = await orchardBalanceToMigrate(accountUUID: resolvedAccountUUID)

        return MigrationDerivations.summary(
            committedSchedule: committedSchedule,
            state: state,
            residual: residual,
            progress: progress,
            orchardBalance: orchardBalance
        )
    }

    /// MOB-1496 W2: derives from the persisted committed schedule + live reads (`getMigrationState`,
    /// `hasOverdueMigrationTransfers`), via `MigrationDerivations.transferRows` — which also takes
    /// the live chain tip (MOB-1513 A3) for each row's real forward ETA. No payload persisted falls
    /// back to the W1 progress-only approximation, kept verbatim below.
    ///
    /// R13 Brick 1: THE one derivation entry both public readers share — `migrationTransfers` and
    /// `migrationViewSnapshot` — returning the rows and the engine statuses those rows were derived
    /// from (`nil` when the engine was not readable in this pass — a degraded read, or the
    /// synthesized fallback).
    ///
    /// Q2-1: used to also cache the rows and stamp view-freshness here, bridging reads that queued
    /// behind proof chunks on the DB write actor (field-caught 2026-08-02, a 33-second blank
    /// screen). The SDK now serves this read from a read-only connection in milliseconds, so every
    /// call derives fresh — the freshness stamp moved to `publishSnapshot`, the one place a build
    /// actually reaches the screen.
    private func transferDerivation(
        accountUUID: AccountUUID?
    ) async -> (rows: [MigrationTransferRow], statuses: [MigrationTransactionStatus]?) {
        await MigrationTrace.timed("migrationTransfers") { await migrationTransfersUntimed(accountUUID: accountUUID) }
    }

    func migrationTransfers(accountUUID: AccountUUID?) async -> [MigrationTransferRow] {
        let derivation = await transferDerivation(accountUUID: accountUUID)
        return stampingActiveSubmit(derivation.rows, accountUUID: accountUUID)
    }

    /// D3/D6: overlays `isSubmitting` on the one transfer row whose id the CURRENT broadcast
    /// session recorded as its own (`activeBroadcastTxIds` — the same D6 source the banner's
    /// "Transfer N is sending" number reads), while `broadcastsInFlight` says a submit call is
    /// open. This is what lights the row's "Sending now" caption during the in-place Send now's
    /// ~7 s window, from the same two facts the banner and the snapshot's `isSubmitting` read —
    /// one clock, three renderings. Applied at the accessor's EXIT, never baked into a stored
    /// derivation: the flag is true only while the call is actually open.
    private func stampingActiveSubmit(_ rows: [MigrationTransferRow], accountUUID: AccountUUID?) -> [MigrationTransferRow] {
        guard
            let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id,
            broadcastsInFlight.withLock({ $0.contains(resolvedAccountUUID) }),
            let activeId = activeBroadcastTxIds.withLock({ $0[resolvedAccountUUID] })
        else { return rows }
        return rows.map { row in
            guard row.id == String(activeId) else { return row }
            var stamped = row
            stamped.isSubmitting = true
            return stamped
        }
    }

    /// GROUND_RULES R11: the last WALLET-CONFIRMED txid set each account derived — the display-form
    /// hex ids (`TransactionState.id` ≡ `SentRecord.txId`, both `toHexStringTxId()`) of every
    /// transaction the wallet's OWN store has observed mined. This is the set that decides which
    /// rows render green: same standard as Activity and the home balances, because it IS their
    /// source (`getAllTransactions`).
    ///
    /// Kept for two reasons of its own. (1) Starvation: the read queues behind prove sweeps like
    /// every other DB read here, and a derivation must not pay for a fresh confirmation read on
    /// every single pass when the confirmed set cannot have changed mid-sweep anyway.
    /// (2) Degradation: a TRANSIENT read failure must not repaint every green row as "Confirming…"
    /// for one derivation pass — on failure the last known set stands. `nil` (no read has EVER
    /// succeeded) tells the derivation to fall back to ENGINE truth rather than un-confirm the
    /// world; see `MigrationDerivations.transferRows`.
    private let walletMinedTxIdsCache = OSAllocatedUnfairLock<[AccountUUID: Set<String>]>(initialState: [:])

    /// R11: the wallet-confirmed txid set for `accountUUID`, freshly read when possible, served
    /// from `walletMinedTxIdsCache` on a failed read, and `nil` only when no read has ever
    /// succeeded for this account (the engine-truth fallback signal).
    private func walletMinedTxIds(accountUUID: AccountUUID) async -> Set<String>? {
        if let transactions = try? await sdkSynchronizer.getAllTransactions(accountUUID) {
            let set = Set(transactions.filter { $0.minedHeight != nil }.map { $0.id })
            walletMinedTxIdsCache.withLock { $0[accountUUID] = set }
            return set
        }
        return walletMinedTxIdsCache.withLock { $0[accountUUID] }
    }

    /// R11, the split's matching gap: the engine's `.mined` state carries NO txid (the SDK model
    /// deliberately omits it), and a note-split PREPARATION has no `SentRecord` either (those are
    /// written for `schedule.transfers` only) — so once a split flips engine-mined there is
    /// nothing left to match against the wallet's store. The txid DOES pass by earlier, in the
    /// `.broadcast(txid:)` state, so it is remembered here (display form, keyed by the engine's
    /// stable status id) and consulted when the same id later reads `.mined`.
    ///
    /// In-memory by nature: an app kill during a split's confirming window forgets the txid, and
    /// the split then falls back to ENGINE truth on the next open — a documented, narrow
    /// degradation, strictly better than the pre-R11 behaviour (green at broadcast) and never
    /// worse. Retires when the SDK exposes the mined txid (its own doc notes upstream now
    /// retains it).
    private let rememberedBroadcastTxIds = OSAllocatedUnfairLock<[AccountUUID: [UInt32: String]]>(initialState: [:])

    /// Harvests `.broadcast(txid:)` payloads from a fresh statuses read into
    /// `rememberedBroadcastTxIds`, and returns the account's full remembered map.
    private func rememberBroadcastTxIds(from statuses: [MigrationTransactionStatus], accountUUID: AccountUUID) -> [UInt32: String] {
        rememberedBroadcastTxIds.withLock { store in
            var map = store[accountUUID] ?? [:]
            for status in statuses {
                if case let MigrationTransactionStatus.State.broadcast(txid) = status.state {
                    map[status.id] = txid.toHexStringTxId()
                }
            }
            store[accountUUID] = map
            return map
        }
    }

    /// True while LONG migration work occupies the `SlipstreamSynchronizer` actor — see the
    /// short-circuit in `reentryRoute`.
    ///
    /// Covers BOTH occupants, and the second one was field-caught 2026-08-02 after the first was
    /// fixed. The prove sweep is the obvious one (tens of seconds). The broadcast is the sneaky one:
    /// a Tor bootstrap plus a submit runs 4–7 s, every broadcast session, and it holds the same
    /// actor. Nine broadcast sessions in one run, nine slow reads, growing with the run:
    ///
    ///     s2 4.09s · s3 4.34s · s4 3.96s · s5 3.56s · s6 6.49s · s7 6.39s · s8 7.02s · s9 6.70s
    ///
    /// A tester tapping the banner during one got a blank screen with a spinner — the 33-second
    /// bug's smaller sibling, in the lane the first fix did not reach. Naming the flag after the
    /// CONDITION (the actor is busy) rather than after one of its causes is what stops a third
    /// occupant from being missed the same way.
    ///
    /// Not a lock and deliberately not one: it never GATES the work. Q2-1 retired every read path
    /// that used to consult it for content (their reads are read-only-connection-fast now, so there
    /// is nothing left worth bridging) — the one remaining reader is `reentryRoute`'s short-circuit,
    /// which treats a `true` reading as license to skip straight to the read-only fallback route
    /// instead of awaiting the still-serialized `migrationAdvanceStep`. A stale read of this flag
    /// costs one overly-conservative route, never a correctness problem.
    private let migrationWorkInFlight = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Audit 2026-08-03 (#13): the accounts whose LAST driver discharge answered `.needsUser` —
    /// a step the app cannot take alone (a Keystone rebuild's signing ceremony, attention that
    /// survived a sync, stalled proving). Recorded by the driver's discharge loop, consumed by
    /// `armNextWindowNotifications`: a blocked run has no prove/send window of its own to poke
    /// about, so without this a backgrounded wallet NEVER learned it was waiting on the user.
    /// In-memory by design — a relaunch re-derives the blocker from the engine on its first open.
    private let stepBlockerAccounts = OSAllocatedUnfairLock<Set<AccountUUID>>(initialState: [])

    /// The driver's per-account blocker record — see `stepBlockerAccounts`.
    func recordStepBlocker(accountUUID: AccountUUID, isBlocked: Bool) {
        stepBlockerAccounts.withLock {
            if isBlocked {
                $0.insert(accountUUID)
            } else {
                $0.remove(accountUUID)
            }
        }
    }

    var isMigrationWorkInFlight: Bool { migrationWorkInFlight.withLock { $0 } }

    /// GOAL 1: whether the wallet is caught up enough to be ASKED about migrating — see the gate in
    /// `bannerVariantUntimed`.
    ///
    /// `.upToDate` is the SDK's own definitive answer and is deliberately preferred to comparing
    /// heights here: a height comparison would need its own tolerance, its own tip source, and would
    /// drift from whatever the synchronizer means by "done". One authority, not two.
    ///
    /// Logs the first transition in each direction rather than every call, because this runs on
    /// every banner derivation and a per-call line would bury the sessions that matter.
    func isCaughtUpForMigrationOffer() -> Bool {
        let caughtUp = sdkSynchronizer.latestState().syncStatus == .upToDate
        let previous = offerGateWasOpen.withLock { was -> Bool? in
            defer { was = caughtUp }
            return was
        }
        if previous != caughtUp {
            let syncState = sdkSynchronizer.latestState()
            MigrationTrace.event(
                "offer gate \(caughtUp ? "OPEN — wallet caught up" : "CLOSED — wallet syncing")"
                + " · status \(syncState.syncStatus) · height \(syncState.latestBlockHeight)"
            )
        }
        return caughtUp
    }

    /// Last observed value of the offer gate, so only its EDGES are logged.
    private let offerGateWasOpen = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    func setMigrationWorkInFlight(_ inFlight: Bool) {
        migrationWorkInFlight.withLock { $0 = inFlight }
    }

    /// GROUND_RULES R3: called by the step driver the moment a session's engine verdict exists.
    /// Ordinal-stamped, so a new app-open (new trace session) automatically reads as "not yet".
    func markSessionVerdictKnown() {
        sessionVerdictOrdinal.withLock { $0 = MigrationTrace.currentSessionOrdinal }
    }

    /// Whether the CURRENT session has heard its first engine verdict. The banner holds
    /// `.checkingStatus` until this is true (R3): iOS presents remembered state before any async
    /// truth can exist, and every migration fact is chain-height-dependent — so no foregrounded
    /// state is provably valid until the engine answers. Outside a traced session (ordinal nil)
    /// this reports `true`: there is no session to hold for, and holding forever would be worse
    /// than the staleness it prevents.
    func isMigrationSessionVerdictKnown() -> Bool {
        guard let ordinal = MigrationTrace.currentSessionOrdinal else { return true }
        return sessionVerdictOrdinal.withLock { $0 } == ordinal
    }

    /// See `migrationTransfers` — the body, wrapped so the flow's own load time is measurable. The
    /// screens behind the banner wait on THIS, and a blank screen with a spinner is this function
    /// not having returned yet.
    /// R13 Brick 1: the untimed derivation now returns the BUNDLE — the rows AND the engine
    /// statuses they were derived from — so `migrationViewSnapshot` can compute the pool-truth
    /// correction from the SAME read its rows came from (one clock; a second statuses fetch inside
    /// the snapshot builder would be exactly the second clock `MigrationViewSnapshot`'s header
    /// forbids). `statuses` is `nil` — meaning "the engine was not readable in this pass", never
    /// "no transactions" — for the synthesized fallback and for a degraded/empty read.
    private func migrationTransfersUntimed(
        accountUUID: AccountUUID?
    ) async -> (rows: [MigrationTransferRow], statuses: [MigrationTransactionStatus]?) {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return ([], nil) }

        guard let committedSchedule = scheduleStorage.committedSchedule(for: resolvedAccountUUID) else {
            // [MOB-1513] W1 fallback, statuses-first: no persisted schedule yet (a restore, or a
            // fresh install mid-migration), so the engine's LIVE per-transaction statuses are the
            // best available signal — see `MigrationDerivations.statusOnlyTransferRows`'s doc for
            // the exact per-row rules. Only when the engine reports no transfer-kind status either
            // (an empty/throwing read) does this fall further back to `synthesizedTransferRows`,
            // the pure progress-count approximation. On a missing account, `[]`.
            let statuses = (try? await sdkSynchronizer.migrationTransactionStatuses(resolvedAccountUUID)) ?? []
            if let statusRows = MigrationDerivations.statusOnlyTransferRows(
                statuses: statuses,
                clock: await chainClock(accountUUID: resolvedAccountUUID),
                isProvingStalled: isProvingStalled,
                confirmedTxIds: await walletMinedTxIds(accountUUID: resolvedAccountUUID)
            ) {
                return (statusRows, statuses.isEmpty ? nil : statuses)
            }
            guard let progress = await migrationProgress(accountUUID: resolvedAccountUUID) else { return ([], nil) }
            return (Self.synthesizedTransferRows(progress: progress), nil)
        }

        let state = await migrationState(accountUUID: resolvedAccountUUID) ?? MigrationState.notStarted
        let hasOverdue = await hasOverdueMigrationTransfers(accountUUID: resolvedAccountUUID)
        // MOB-1513 (T-A): the engine's LIVE per-transaction statuses — preferred over the persisted
        // schedule's own app-derived state/heights for each transfer row (see
        // `MigrationDerivations.transferRows`'s doc). A throw or an empty read (no run stored, or a
        // transient SDK error) degrades to `[]`, which keeps `transferRows`'s existing R3-A3
        // persisted-schedule derivation fully in play — never a crash, never a blank screen.
        let statuses = (try? await sdkSynchronizer.migrationTransactionStatuses(resolvedAccountUUID)) ?? []

        let rows = MigrationDerivations.transferRows(
            committedSchedule: committedSchedule,
            state: state,
            hasOverdueMigrationTransfers: hasOverdue,
            now: Date(),
            clock: await chainClock(accountUUID: resolvedAccountUUID),
            statuses: statuses,
            isProvingStalled: isProvingStalled,
            confirmedTxIds: await walletMinedTxIds(accountUUID: resolvedAccountUUID)
        )
        return (rows, statuses.isEmpty ? nil : statuses)
    }

    /// [MOB-1496] W1 fallback of last resort: no persisted schedule AND no live transfer statuses
    /// either (MOB-1513 — `statusOnlyTransferRows` returned `nil`) — rows are synthesized purely
    /// from `getMigrationProgress`'s counts: index < completedTransfers reads `.sent`, everything
    /// else `.pending` (no `.active`/`.overdue`/`.invalid`/`.expired` — those need per-transfer
    /// identity neither progress nor an absent status list can carry); `hoursFromNow` is a rough
    /// `(index - completed) × 6h` cadence estimate, clamped ≥ 0. `amount` is `nil` (unknown — never
    /// a placeholder `Zatoshi.zero`); `id` is a placeholder ordinal. Shared by the public
    /// `migrationTransfers(accountUUID:)` and `bannerVariant`'s own row derivation (R8-T3 #23),
    /// which otherwise would have re-derived this independently after already fetching `progress`.
    private static func synthesizedTransferRows(progress: MigrationProgress) -> [MigrationTransferRow] {
        (0..<progress.totalTransfers).map { index in
            MigrationTransferRow(
                id: "\(index)",
                index: index,
                amount: nil,
                status: index < progress.completedTransfers ? MigrationTransferRow.Status.sent : MigrationTransferRow.Status.pending,
                hoursFromNow: max(0, (index - progress.completedTransfers) * 6)
            )
        }
    }

    /// R8-T3 (#23): `bannerVariant`'s own row derivation — mirrors `migrationTransfers(accountUUID:)`'s
    /// branching logic exactly, but takes `state`/`hasOverdue`/`progress` already fetched by the
    /// caller instead of re-reading them (this file's public `migrationTransfers` keeps its own
    /// independent reads unchanged; only the W1-fallback synthesis is shared, via
    /// `synthesizedTransferRows`, to avoid coupling the two methods' read patterns together).
    ///
    /// MOB-1513 (W1 fallback wave 2): `async` — it reads the engine's live per-transaction
    /// statuses itself rather than being handed a caller-prefetched value.
    ///
    /// MOB-1466 (smart-banner pass) — THE FIX for the banner/timeline desync, and the reason that
    /// read is now unconditional. The committed-schedule branch below used to call `transferRows`
    /// with `statuses:` OMITTED. It is a defaulted argument, so the call compiled and read as
    /// complete; what it meant was that the BANNER derived its rows purely from the persisted
    /// schedule's position table while the TIMELINE (`migrationTransfers`, sixty lines above) fed
    /// the identical function the engine's live statuses.
    ///
    /// Two surfaces, one derivation, different inputs. The banner could not see `.broadcast` (so
    /// `isBroadcasting` was never true for it, and `.transferSending` was unreachable by that
    /// route), could not see live `.mined` ahead of the app's own sent-record bookkeeping, and
    /// could not see `isReady`/`nextAction` at all. Every "the banner disagrees with the timeline"
    /// report traces here: they were reading different clocks because one of them was handed a
    /// stopped one. The extra round-trip the old lazy read saved is the price of the banner being
    /// true.
    ///
    /// Returns both row lists: `transfers` (the numbered crossing transfers — the only ones the
    /// banner ever counts) and `preparations` (the note-split transactions, which carry no display
    /// number but are just as much work-in-flight — see `bannerVariant`'s `isPreparingRun`).
    ///
    /// P3: takes the caller's already-read `clock` rather than reading its own — same one-read-each
    /// discipline as `progress`/`hasOverdue` above. `bannerVariant` needs the clock for its own
    /// due-ness check anyway, so a second read here would be a wasted pair of round-trips per pass.
    /// WHY the banner is what it is — the deciding input, named, not a restatement of the variant.
    ///
    /// MOB-1466. A transition line without a reason is a fact ("it changed"); with one it is a
    /// diagnosis ("it changed because the submit finished"). The order here mirrors
    /// `MigrationDerivations.bannerVariant`'s own precedence exactly, so the reason is always the
    /// arm that actually fired rather than a plausible-looking guess assembled separately.
    private func bannerReason(
        state: MigrationState,
        rows: [MigrationTransferRow],
        preparations: [MigrationTransferRow],
        hasOverdue: Bool,
        isBroadcastInFlight: Bool
    ) -> String {
        if case MigrationState.notStarted = state {
            return "no run"
        }
        if isBroadcastInFlight {
            return "submitting now"
        }
        let isProvable = (rows + preparations).contains { $0.isPreparing }

        // The split phase has its OWN arm in `bannerVariant`, which never consults `hasOverdue` —
        // so neither may this. Caught by reading the instrument's own output: a
        // `splitPendingConfirmation` line printed `why: window passed` while the arm that fired had
        // not looked at overdue-ness at all. A reason assembled from a different precedence than the
        // decision is worse than no reason, because it reads like an explanation.
        if case MigrationState.splitPendingConfirmation = state {
            let mined = preparations.filter { $0.status == MigrationTransferRow.Status.sent }.count
            // FIND-8 (2026-08-05): "the prove sweep will run this session" dwelt for 70+ minutes
            // in a marathon session whose one credited sweep had already run — a promise the
            // session could no longer keep. The reason now names the discharge that actually
            // serves it (the sync edge, or any 30s tick — FIND-5 made ticks prove
            // unconditionally), which holds however long the session lasts.
            return isProvable
                ? "split phase — provable now, a prove discharge is due (sync edge or tick)"
                : "split phase — \(mined)/\(preparations.count) preparations mined, waiting on the next step"
        }
        if isProvingStalled {
            return "PROVE STALLED — the engine reports rows ready to prove and sweeps produce nothing"
        }
        if isProvable {
            return "provable now — a prove discharge is due (sync edge or tick)"
        }
        if let sending = (preparations + rows).first(where: { $0.isBroadcasting }) {
            return "on the wire (\(sending.kind == .splitBalance ? "split" : "transfer") \(sending.index + 1)), awaiting mining"
        }
        if hasOverdue {
            return "window passed"
        }
        let done = rows.filter { $0.status == MigrationTransferRow.Status.sent }.count
        return "idle — \(done)/\(rows.count) mined, waiting on the next window"
    }

    // (R13 Brick 2b: `bannerTransferRows` — the banner's mirror row derivation — is deleted. THE
    // rows come from `transferDerivation`'s bundle, and `bannerArm` receives them from the loader's
    // one pass.)

    /// MOB-1496 (W2): persists the just-committed schedule for `accountUUID` (`nil` resolves the
    /// selected account, same convention as `migrationSummary`/`migrationTransfers` above) — the
    /// SDK retains no proposal list post-commit, so this is the app's only record of it. Replaces
    /// any existing payload's `schedule`/`committedAt` while preserving its `sentRecords` (a
    /// restart/re-created plan continues the same logical run). R8-T3 (#18): serialized against
    /// `reconcile`/`acknowledgeComplete`/`clearAbandonedNetworkSnapshot` — see
    /// `MigrationManagerSerialExecutor`'s doc; this is the "commit" half of the TOCTOU `reconcile()`
    /// otherwise races.
    ///
    /// MOB-1497: also stamps the account's network snapshot committed (`markNetworkSnapshotCommitted`)
    /// — this is the SINGLE production call site for that stamp, deliberately co-located here rather
    /// than duplicated at each of `recordCommittedSchedule`'s several external callers (software
    /// sign+store success in `MigrationTransferPlanStore`/`MigrationReviewTransferStore`, Keystone
    /// deferred store success in `MigrationCoordFlowCoordinator.resolvePendingScheduleStore` (the
    /// first-delivery kick, MOB-1513 B4), the
    /// Keystone no-split immediate store, and the software dust commit) so the schedule commit and
    /// the snapshot commit can never drift out of sync. Ordered after the schedule write: a snapshot
    /// briefly still reading provisional while the schedule is already durable is harmless (nothing
    /// reads `committedAt` in that narrow window), whereas the reverse order risks a snapshot that
    /// reads committed for a schedule write that then fails. The stamp rides INSIDE the same
    /// serialized critical section as the schedule write (rebase of MOB-1497 onto R8-T3): it is a
    /// mutating pass over the same per-run storage pair the executor exists to serialize.
    /// MOB-1466: stamps THIS run's persisted payload as user-cancelled. Serialized with
    /// `recordCommittedSchedule`/`reconcile` on the same executor, so the mark and a concurrent
    /// commit can never interleave — a commit that lands after this must win, and it does, because
    /// it replaces the payload the mark lives in.
    func markRunCancelledByUser(accountUUID: AccountUUID?) async {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
        await serialExecutor.run { [self] in
            scheduleStorage.markRunCancelledByUser(for: resolvedAccountUUID, now: Date())
        }
        LoggerProxy.event("\(Self.logTag) run marked CANCELLED BY USER — the banner will re-offer migration")
    }

    func recordCommittedSchedule(accountUUID: AccountUUID?, schedule: MigrationSchedule) async {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
        await serialExecutor.run { [self] in
            scheduleStorage.recordCommittedSchedule(schedule, for: resolvedAccountUUID, now: Date())
            markNetworkSnapshotCommitted(accountUUID: resolvedAccountUUID)
        }
        // G1 (field 2026-08-05, Lukas: the Start-migration button should trigger the first
        // `nextStep`, not a later session): a committed schedule is a NEWBORN run, and the
        // session's open-lane credits were typically spent on the PRE-commit "noRun" pass —
        // refund them so the commit delegate's immediate drive (`RootCoordinator`) is not
        // refused. R0's law bans re-driving the SAME state twice per open; a run that did not
        // exist at the earlier drive is not the same state. Open lanes only — the tick lane
        // has no credit here and keeps its own governance (belt, buffer, engine schedule).
        openLaneCredits.withLock {
            $0.beforeSyncSpentSession = nil
            $0.afterSyncSpentSession = nil
        }
        MigrationTrace.event("R0 open-lane credits refunded — a fresh schedule was committed; the commit's own drive may proceed")
        // A newborn run must not wait for the next poke to appear on screen: publish now.
        refreshMigrationSnapshot(accountUUID: resolvedAccountUUID)
    }

    /// MOB-1496 (W2): records a successful transfer broadcast against the persisted schedule;
    /// non-success results and a missing payload (nothing to append against) are both no-ops — see
    /// `MigrationScheduleStorage.recordTransferBroadcast`.
    ///
    /// MOB-1466 (M2, SDK delegation): the record is keyed to the transfer the lane ACTUALLY
    /// served, resolved here (`resolveServedTransferId`) — never inferred from row position alone.
    /// The engine's delivery order is schedule-slot order, not the persisted array's crossing
    /// order, so the old first-unsent positional guess could attribute a landed broadcast to the
    /// wrong transfer; it survives only as the unresolvable-id fallback inside the storage layer.
    ///
    /// MOB-1497 (R7-T3): this is the manager-layer chokepoint every LANDED-broadcast lane funnels
    /// through — FG send (`MigrationSendingStore`, including the dust lane), the coordinator's
    /// post-confirm first-delivery kick, and BG (`RootInitialization.handleLandedBroadcast`) — so a
    /// `.success` here also marks the had-broadcast flag (R14 first-run vs R15 mid-run) and resets
    /// the R16 episode set (a fresh episode starts with every new transfer attempt window).
    ///
    /// MOB-1513 (B4) prep-phase guard: the reordered confirm chain app-records the schedule at
    /// commit time, BEFORE any preparation (note-split) broadcast — the pre-B4 "every note-split
    /// broadcast happens before `recordCommittedSchedule`, so the schedule-storage append is a
    /// harmless no-op" timing assumption (flagged in the T3 report) no longer holds. A landed
    /// broadcast recorded while the engine still reports `.splitPendingConfirmation` is a
    /// PREPARATION transaction, not one of the schedule's transfers ("the run is committed and its
    /// preparation transactions are not yet all mined" — the state only advances to `.inProgress`
    /// once every prep is mined, so a schedule transfer can never land during it): it marks the
    /// had-broadcast flag but must append NO schedule sent record, or the status/plan rows would
    /// show transfers as sent that never broadcast. An UNREADABLE state (the read throws, `nil`)
    /// keeps today's append — the guard only fires on a positively identified prep phase, never as
    /// a new way to silently drop a real transfer's record.
    func recordTransferBroadcast(accountUUID: AccountUUID?, result: MigrationTransferResult) async {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
        if case MigrationTransferResult.success = result {
            failureRoutingStorage.markHadBroadcast(for: resolvedAccountUUID)
        }
        if await migrationState(accountUUID: resolvedAccountUUID) == MigrationState.splitPendingConfirmation {
            // Deliberate discard, now SAID (audit 2026-08-03, #19): a preparation-phase broadcast
            // is not a schedule transfer, so it must not enter the sent-records ledger — but the
            // one write-discarding guard in this layer staying silent broke the file's own
            // "never silence" discipline.
            LoggerProxy.debug("\(Self.logTag) broadcast record skipped — split phase, not a schedule transfer")
            return
        }
        let servedTransferId = await resolveServedTransferId(accountUUID: resolvedAccountUUID, result: result)
        scheduleStorage.recordTransferBroadcast(result, transferId: servedTransferId, for: resolvedAccountUUID, now: Date())
    }

    /// MOB-1466 (M2, SDK delegation): the transfer id a landed broadcast belongs to, or `nil` when
    /// nothing can vouch for one (the storage layer then falls back to its legacy positional
    /// guess).
    ///
    /// Resolution order:
    /// 1. Live-status txid match — exact and race-free: the engine's own record of the submit puts
    ///    the row in `.broadcast(txid:)` before the executor returns, and the payload is RAW byte
    ///    order while `success(txId:)` speaks display-form hex, so the comparison converts via
    ///    `toHexStringTxId()` (the same convention `transferRows`' confirmation matching uses).
    ///    Only `.transfer`-kind rows are considered — a preparation's broadcast must never claim a
    ///    schedule row (the split-phase guard above already drops the whole record during the prep
    ///    phase; this keeps the belt on outside it).
    /// 2. The D6 in-flight marker (`activeBroadcastTxIds`) — the id THIS session submitted, still
    ///    set while the headless lane records; covers the landed-but-record-failed empty-txid
    ///    shape, which has no txid to match. The manual send lane sets no marker and resolves via
    ///    the txid alone.
    private func resolveServedTransferId(accountUUID: AccountUUID, result: MigrationTransferResult) async -> UInt32? {
        if case let MigrationTransferResult.success(txId) = result, !txId.isEmpty {
            let statuses = (try? await sdkSynchronizer.migrationTransactionStatuses(accountUUID)) ?? []
            let matched = statuses.first { status in
                guard case MigrationTransactionStatus.Kind.transfer = status.kind else { return false }
                guard case let MigrationTransactionStatus.State.broadcast(txid) = status.state else { return false }
                return txid.toHexStringTxId() == txId
            }
            if let matched {
                return matched.id
            }
        }
        return activeBroadcastTxIds.withLock { $0[accountUUID] }
    }

    /// MOB-1496: "Lock balance" now calls the SDK's real `lockMigrationResidual` directly — the
    /// cosmetic `Task.sleep` + app-persisted `gateStorage.setDustLocked` bookkeeping this replaces
    /// (pre-real-SDK stand-in) is gone; the lock itself is now genuine and its state lives in the
    /// account's own `PoolBalance.lockedValue` (see `isMigrationDustLocked` below), not a local
    /// flag. The returned locked total is discarded here — this member is `Void`-returning; a
    /// caller that needs the amount reads it back via balance, same as everywhere else in the app.
    func lockMigrationDust(accountUUID: AccountUUID?) async throws {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
        _ = try await sdkSynchronizer.lockMigrationResidual(resolvedAccountUUID)
    }

    /// MOB-1496: balance-derived now — a nonzero Orchard `PoolBalance.lockedValue` means the
    /// residual is locked. Async (a live SDK balance read) where the pre-real-SDK stand-in was a
    /// synchronous `UserDefaults` read; degrades to `false` on an unresolvable account or a failed
    /// balance read, same "safe default" convention as `orchardBalanceToMigrate` below.
    func isMigrationDustLocked(accountUUID: AccountUUID?) async -> Bool {
        await migrationLockedAmount(accountUUID: accountUUID) > Zatoshi.zero
    }

    /// MOB-1496: the locked remainder amount itself — the account's Orchard
    /// `PoolBalance.lockedValue`. This is the value the Complete screen's locked confirmation
    /// shows on re-entry: `migrationSummary().dust` derives from `residualAfterMigration`, which
    /// re-plans from live *spendable* notes once the migration state is terminal, so it silently
    /// reads zero after a lock — the locked value is the signal that stays correct. `.zero` on an
    /// unresolvable account or a failed balance read, same convention as `isMigrationDustLocked`.
    func migrationLockedAmount(accountUUID: AccountUUID?) async -> Zatoshi {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return Zatoshi.zero }
        guard let balances = try? await sdkSynchronizer.getAccountsBalances(),
              let balance = balances[resolvedAccountUUID] else {
            return Zatoshi.zero
        }
        return balance.orchardBalance.lockedValue
    }

    /// MOB-1509: per-account persisted prefs (mode, manual delivery) — `nil` resolves the selected
    /// account, same convention as `migrationSummary`/`stateEvents`. An unresolvable account reads
    /// the defaults and writes nowhere.
    func migrationMode(accountUUID: AccountUUID?) -> MigrationMode? {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return nil }
        return gateStorage.migrationMode(for: resolvedAccountUUID)
    }

    func setMigrationMode(accountUUID: AccountUUID?, mode: MigrationMode) {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
        gateStorage.setMigrationMode(mode, for: resolvedAccountUUID)
    }

    /// MOB-1496: per-account replacement for the old wallet-wide `migrationStateStream`. `nil`
    /// resolves the selected account; a genuinely unresolvable account (neither passed in nor
    /// selected) gets an inert, never-emitting stream rather than a crash.
    func stateEvents(accountUUID: AccountUUID?) -> AnyPublisher<MigrationState, Never> {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else {
            return Empty().eraseToAnyPublisher()
        }
        return subject(for: resolvedAccountUUID).eraseToAnyPublisher()
    }

    /// MOB-1496 (W4): ensure-or-read `accountUUID`'s atomic network snapshot, mapped onto the SDK's
    /// `MigrationNetworkPrivacyOptions`. See `MigrationManagerClient.migrationNetworkOptions`'s doc
    /// for the full contract (idempotent, never throws).
    ///
    /// MOB-1497 (R9-T6, finding 8): safe to call from ANYWHERE, including from inside another
    /// dependency's `transactionGuard.withSubmission`/`switchIfIdle`/`switchWaiting` block — forming
    /// (`ensureOrCreateNetworkSnapshot` below) no longer touches `transactionGuard` at all, and never
    /// actually needed to: it reads/writes only `zcashSDKEnvironment.endpoint()` (UserDefaults-
    /// backed), the migration gate's Tor flag (UserDefaults, self-locked), `migrationRandomness
    /// .randomIndex` (pure), and `snapshotStorage` (atomic under its own `OSAllocatedUnfairLock`) —
    /// never the live synchronizer, so the hazard the guard exists for (`switchTo(endpoint:)`
    /// tearing down the synchronizer under an in-flight broadcast) cannot touch it. The one thing
    /// the guard incidentally provided — closing the "check absent -> create -> write" race between
    /// two concurrent formers for the SAME account — is now closed at the storage layer instead; see
    /// `ensureOrCreateNetworkSnapshot`'s doc.
    func migrationNetworkOptions(accountUUID: AccountUUID?) async -> MigrationNetworkPrivacyOptions {
        let snapshot = await ensureNetworkSnapshot(accountUUID: accountUUID)
        return MigrationNetworkPrivacyOptions(useTor: snapshot.useTor, submissionEndpoint: snapshot.broadcastEndpoint.toLightWalletEndpoint())
    }

    /// MOB-1497: forms (or, idempotently, returns the existing) provisional network snapshot for
    /// `accountUUID` — called by the coordinator at the Tor-choice RESOLUTION points (the Tor sheet's
    /// confirm, and the sheet-skipped app-wide-Tor-on shortcut, on both the immediate and scheduled
    /// entry chains). Shares `ensureOrCreateNetworkSnapshot`'s body with `ensureNetworkSnapshot`
    /// below, `stampCommitted: false` — a freshly created snapshot here stays PROVISIONAL
    /// (`committedAt == nil`) until `markNetworkSnapshotCommitted` stamps it at schedule-commit. A
    /// re-entry path that never shows the Tor step never calls this, so it never forms one; if an
    /// already-COMMITTED snapshot from an earlier session exists, this naturally just returns it
    /// unchanged (mid-run idempotence — see the guard inside `ensureOrCreateNetworkSnapshot`).
    ///
    /// R7-review fix (Important-1): `reformIfProvisional: true` — a still-PROVISIONAL existing
    /// snapshot is discarded and re-formed from the CURRENT stored Tor choice and a fresh random
    /// roll, rather than returned as-is. Without this, a provisional snapshot left behind by an
    /// abandoned attempt (app killed before commit, or a same-session back-and-reconfirm) has no
    /// cleanup path other than flow teardown (`clearProvisionalNetworkSnapshot`, which only runs on
    /// an in-app close) — so it would silently outlive the attempt that made it, and THIS run's fresh
    /// Tor choice at the sheet would never reach the snapshot a later broadcast reads. Worst case: a
    /// clearnet broadcast under a screen that showed Tor ON. Always safe to re-form here: nothing has
    /// broadcast against a snapshot that hasn't committed yet (a COMMITTED existing snapshot is never
    /// reformed — see below), so "made at migration start and held for the run" (R4/R7) attaches to
    /// the run that is actually starting now, not to an abandoned one.
    func formNetworkSnapshot(accountUUID: AccountUUID?) async {
        _ = await ensureOrCreateNetworkSnapshot(accountUUID: accountUUID, stampCommitted: false, reformIfProvisional: true)
    }

    /// MOB-1497 (T2): read-only peek — see `MigrationManagerClient.networkSnapshot`'s doc. Never
    /// forms/creates; never touches `transactionGuard` (no creation can happen here, so there's
    /// nothing to serialize against a mid-flight server switch).
    func networkSnapshot(accountUUID: AccountUUID?) async -> MigrationNetworkSnapshot? {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return nil }
        return snapshotStorage.snapshot(for: resolvedAccountUUID)
    }

    /// MOB-1497 (T2): see `MigrationManagerClient.confirmProvisionalTorChoice`'s doc. Purely a
    /// storage mutation (no SDK/network interaction), so — like `markNetworkSnapshotCommitted`/
    /// `clearProvisionalNetworkSnapshot` beside it — this doesn't need `transactionGuard` either.
    func confirmProvisionalTorChoice(accountUUID: AccountUUID?, useTor: Bool) {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
        snapshotStorage.updateUseTorIfProvisional(useTor, for: resolvedAccountUUID)
    }

    /// MOB-1497: stamps `accountUUID`'s persisted network snapshot committed. A no-op when no
    /// snapshot is persisted (defensive — should not happen for a live commit, since
    /// `formNetworkSnapshot` always runs first) or when it is already committed (idempotent) — see
    /// `MigrationSnapshotStorage.markCommitted`. Production has exactly one call site,
    /// `recordCommittedSchedule` above (inside its serialized critical section) — see that method's
    /// doc for why.
    ///
    /// R7 final review, Minor M-A: also resets the R16 episode set here — a NEW run committing is a
    /// reliable "this account's endpoint-rotation history starts fresh" signal no matter how the
    /// committing snapshot got here (freshly formed, or `formNetworkSnapshot`'s own
    /// `reformIfProvisional` reform over a stale provisional left by an abandoned earlier attempt —
    /// see that method's doc). Without this, a stale episode from an abandoned attempt (e.g. a
    /// Keystone note-split that rotated/exhausted pre-commit, then got closed without committing)
    /// could survive into a later attempt and trigger R17's provider-exhausted consent before a
    /// fresh sweep of the provider's endpoints actually happened this run. EPISODE ONLY — never the
    /// had-broadcast flag: a landed note-split broadcast before an abandoned deferred-store commit
    /// means a re-entry that later commits genuinely IS mid-run, and clearing the flag here would
    /// wrongly re-open an R14 clearnet offer on a run that already has a landed transaction (the
    /// unsafe direction).
    func markNetworkSnapshotCommitted(accountUUID: AccountUUID?) {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
        snapshotStorage.markCommitted(for: resolvedAccountUUID, now: Date())
        failureRoutingStorage.resetEpisode(for: resolvedAccountUUID)
    }

    /// MOB-1497: discards `accountUUID`'s persisted network snapshot ONLY while still provisional —
    /// a no-op against an already-committed one. Called at migration flow teardown (`RootCoordinator`'s
    /// `.migrationCoordFlow(.flowFinished)` path-clearing site — the flow's one teardown point; a
    /// second call site at the Sending `.viewTransaction` delegate was removed as a dead no-op, since
    /// reaching Sending always implies an already-committed snapshot) so closing the flow without
    /// committing discards the provisional pick; a re-entry re-forms and re-rolls. See
    /// `MigrationSnapshotStorage.clearIfProvisional`. Complementary to R8-T3's
    /// `clearAbandonedNetworkSnapshot` (which guards on engine `.notStarted` + no stored payload and
    /// handles COMMITTED-but-dead leftovers): this one only ever touches a provisional pick.
    func clearProvisionalNetworkSnapshot(accountUUID: AccountUUID?) {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
        snapshotStorage.clearIfProvisional(for: resolvedAccountUUID)
    }

    /// MOB-1496 (W4): every persisted network snapshot across every candidate account — i.e. every
    /// account with a currently-active migration run. Drives `AutoServerSelectionLiveKey`'s pinning
    /// and `ServerSetupStore`'s manual-switch privacy warning. R8-T3: sourced from
    /// `MigrationDerivations.candidateAccountUUIDs` — this used to hand-roll its own
    /// walletAccounts-then-selected account list (opposite order, own ad-hoc dedup), which disagreed
    /// with `reconcile()`'s/the BG scheduler's selected-first order; nothing here depends on a
    /// specific order (only presence), so unifying onto the shared helper is a pure simplification.
    func activeNetworkSnapshots() -> [MigrationNetworkSnapshot] {
        let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: selectedWalletAccount?.id,
            walletAccounts: walletAccounts
        )
        return accountUUIDs.compactMap { snapshotStorage.snapshot(for: $0) }
    }

    /// MOB-1497 (R7-T3): the failure-routing decision for a classified broadcast failure — see
    /// `MigrationBroadcastFailureRoute`'s doc for what each case means to a caller. Storage-locked
    /// where it touches storage: the had-broadcast flag / R16 episode set live in
    /// `failureRoutingStorage` (read/written directly here — neither is part of the network
    /// snapshot); the snapshot's `broadcastEndpoint` is mutated ONLY via the sanctioned
    /// `snapshotStorage.rotateBroadcastEndpoint` below.
    ///
    /// R7-review fix (Important-1): operates on the run's ACTIVE snapshot — the COMMITTED one if
    /// present, else the still-PROVISIONAL one — rather than requiring a committed snapshot. The live
    /// Keystone prep lane broadcasts BEFORE its schedule (and therefore its snapshot) commits,
    /// by design: `MigrationCoordFlowCoordinator.runFirstDeliveryKick` (MOB-1513 B4) defers
    /// `recordCommittedSchedule`/`markNetworkSnapshotCommitted` until AFTER a prep's OWN broadcast
    /// succeeds (see that method's doc for why — this ordering is untouched by this fix). Requiring
    /// `committedAt != nil` here meant every note-split failure fell through to the defensive
    /// `.plainRetry` below, so R14/R16/R17 never engaged on that lane. Since at most one snapshot is
    /// ever persisted per account at a time (provisional XOR committed), `snapshotStorage.snapshot(for:)`
    /// already returns whichever one is active — no extra lookup needed. A mutation applied here to a
    /// still-provisional snapshot is carried forward automatically once `markNetworkSnapshotCommitted`
    /// later stamps it (that stamps whatever is currently persisted, mutated or not), so a
    /// rotated/overridden choice survives the commit.
    ///
    /// Decision table (normative doc R14-R17):
    /// - NO active (committed or provisional) network snapshot for the account (defensive — should
    ///   not happen for a live broadcast, since one is always formed well before a broadcast is
    ///   attempted) -> `.plainRetry`, logged.
    /// - `.torUnavailable` -> `.torFirstRunChoice` (R14) when the account has never had a landed
    ///   broadcast this run, else `.torHold` (R15). NEVER rotates or touches the episode: a Tor-class
    ///   failure says nothing about which endpoint is reachable, so leaking a rotation decision off
    ///   it would be wrong.
    /// - `.endpointUnreachable` + same-server snapshot (`broadcastProvider == syncProvider` — covers
    ///   identity-custom AND the defensive empty-candidates/testnet fallback in
    ///   `createNetworkSnapshot`) -> `.plainRetry` (R16 exemption: nothing to rotate to, so R17 can
    ///   never fire either). No episode tracking.
    /// - `.endpointUnreachable` + provider snapshot: add the CURRENT `broadcastEndpoint.host` to the
    ///   episode set, then candidates = the shipped endpoints for `broadcastProvider` (the SAME
    ///   source `createNetworkSnapshot` draws from) minus every host tried this episode. Non-empty ->
    ///   rotate to a uniform-random candidate (`migrationRandomness.randomIndex`, the SAME seam R7
    ///   uses) and return `.retryRotated`. Empty (the episode now covers the whole shipped list — 5
    ///   for P1/zecRocks, 2 for P2/stardust) -> `.providerExhausted(torEnabled:)`, WITHOUT rotating
    ///   anything — the episode itself stays full (nothing resets it except a landed broadcast or the
    ///   R17 sync-server override), so a REPEATED failure keeps returning `.providerExhausted`.
    ///
    /// R7 final review, Important-1 (spec §G): single chokepoint for `failureRoutingStorage`'s
    /// Tor-hold indicator — right before returning, persists whether the route ABOUT TO BE RETURNED
    /// is `.torHold` (`true`) or anything else (`false`, including the defensive no-snapshot
    /// fallback and `.torFirstRunChoice` — a first-run Tor failure is a foreground CHOICE point, not
    /// a silent hold). This is what lets the waiting/stalled surfaces show a Tor-specific line
    /// without the BG lane needing any UI of its own: BG already discards the route for presentation
    /// purposes (see `RootInitialization.executeBroadcastAction`), but it calls this SAME member, so
    /// the indicator persists regardless of which lane called it.
    func routeBroadcastFailure(accountUUID: AccountUUID?, failureClass: MigrationBroadcastFailureClass) async -> MigrationBroadcastFailureRoute {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else {
            LoggerProxy.warn("[MigrationManagerImpl] routeBroadcastFailure: no account to route against — defaulting to plainRetry.")
            return MigrationBroadcastFailureRoute.plainRetry
        }
        guard let snapshot = snapshotStorage.snapshot(for: resolvedAccountUUID) else {
            LoggerProxy.warn("[MigrationManagerImpl] routeBroadcastFailure: no active network snapshot for the account — defaulting to plainRetry.")
            failureRoutingStorage.setTorHoldActive(false, for: resolvedAccountUUID)
            return MigrationBroadcastFailureRoute.plainRetry
        }

        let route: MigrationBroadcastFailureRoute
        switch failureClass {
        case MigrationBroadcastFailureClass.torUnavailable:
            let hadBroadcast = failureRoutingStorage.hadBroadcast(for: resolvedAccountUUID)
            route = hadBroadcast ? MigrationBroadcastFailureRoute.torHold : MigrationBroadcastFailureRoute.torFirstRunChoice

        case MigrationBroadcastFailureClass.endpointUnreachable:
            if snapshot.broadcastProvider == snapshot.syncProvider {
                route = MigrationBroadcastFailureRoute.plainRetry
            } else {
                let episodeHosts = Set(failureRoutingStorage.addEpisodeHost(snapshot.broadcastEndpoint.host, for: resolvedAccountUUID))
                let network = zcashSDKEnvironment.network().networkType
                let candidates = ZcashSDKEnvironment.endpoints(for: network, skipDefault: false).filter { candidate in
                    ServerProvider.classify(host: candidate.host) == snapshot.broadcastProvider && !episodeHosts.contains(candidate.host)
                }

                if candidates.isEmpty {
                    route = MigrationBroadcastFailureRoute.providerExhausted(torEnabled: snapshot.useTor)
                } else {
                    let index = migrationRandomness.randomIndex(candidates.count)
                    let chosen = MigrationNetworkSnapshot.Endpoint(candidates[index])
                    snapshotStorage.rotateBroadcastEndpoint(to: chosen, for: resolvedAccountUUID)
                    route = MigrationBroadcastFailureRoute.retryRotated
                }
            }
        }

        failureRoutingStorage.setTorHoldActive(route == MigrationBroadcastFailureRoute.torHold, for: resolvedAccountUUID)
        // F#9 (MOB-1497 T5 completion): the same chokepoint persists the first-run-choice latch,
        // so the HEADLESS lane — which discards the returned route for presentation — still leaves
        // the choice visible to the snapshot pipeline (banner Tor line + Status sheet).
        failureRoutingStorage.setPendingTorPrompt(route == MigrationBroadcastFailureRoute.torFirstRunChoice, for: resolvedAccountUUID)
        return route
    }

    /// MOB-1497 (R7-T3, R14): see `MigrationManagerClient.overrideTorForRun`'s doc. Purely a storage
    /// mutation (no SDK/network interaction), so — like `markNetworkSnapshotCommitted`/
    /// `confirmProvisionalTorChoice` above — this doesn't need `transactionGuard` either.
    ///
    /// R7-review fix (Important-1): mutates the account's ACTIVE snapshot (committed-else-provisional)
    /// — see `routeBroadcastFailure`'s doc for why (the note-split lane's R14 choice can fire against
    /// a still-provisional snapshot).
    func overrideTorForRun(accountUUID: AccountUUID?, useTor: Bool) {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
        snapshotStorage.overrideUseTorOnActiveSnapshot(useTor, for: resolvedAccountUUID)
        // F#9: the override IS the first-run choice being made — the pending prompt is consumed
        // regardless of which surface presented it.
        failureRoutingStorage.setPendingTorPrompt(false, for: resolvedAccountUUID)
    }

    /// F#9 (MOB-1497 T5 completion): consumes the pending first-run Tor prompt WITHOUT changing the
    /// Tor choice — the "Cancel" resolution (keep Tor, wait). The latch re-arms on the next failed
    /// attempt if Tor is still unreachable, so dismissing is never a permanent silence. Republishes
    /// so every surface drops the prompt in the same pass.
    func resolveTorPrompt(accountUUID: AccountUUID?) async {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
        failureRoutingStorage.setPendingTorPrompt(false, for: resolvedAccountUUID)
        await reconcile()
    }

    /// MOB-1497 (R7-T3, R17): see `MigrationManagerClient.overrideBroadcastEndpointToSyncServer`'s
    /// doc. `async` to match the client's closure shape (a future implementation detail could need
    /// to suspend); today's body has no actual `await` — same no-network-call reasoning as the other
    /// sanctioned mutations.
    ///
    /// R7-review fix (Important-1): mutates the account's ACTIVE snapshot (committed-else-provisional)
    /// — see `routeBroadcastFailure`'s doc for why.
    func overrideBroadcastEndpointToSyncServer(accountUUID: AccountUUID?) async {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
        snapshotStorage.overrideBroadcastEndpointToSyncServerOnActiveSnapshot(for: resolvedAccountUUID)
        failureRoutingStorage.resetEpisode(for: resolvedAccountUUID)
    }

    /// Persists the pre-run Tor choice — consumed the next time THIS account's snapshot is first
    /// taken (`createNetworkSnapshot`'s `useTor` read). Does not alter an already-active run's
    /// snapshot (see `MigrationNetworkSnapshot.useTor`'s doc).
    func setNetworkPrivacyOptions(useTor: Bool) {
        gateStorage.setTorEnabledForMigration(useTor)
    }

    /// MOB-1496 (W4) safety net: ensure-or-read `accountUUID`'s atomic per-run network snapshot for a
    /// lane that reaches a broadcast without one already formed (e.g. the BG executor on a mid-run
    /// account after a reinstall-edge — a snapshot from before this device had ever seen the Tor
    /// sheet). Shares `ensureOrCreateNetworkSnapshot`'s body with `formNetworkSnapshot` above,
    /// `stampCommitted: true` (MOB-1497): a broadcast-bearing read implies a committed run reached
    /// this point some other way, so a snapshot created HERE is stamped committed immediately rather
    /// than left provisional forever — this lane has no guaranteed later `recordCommittedSchedule`
    /// call to stamp it (a bare dust broadcast, for one, commits no schedule at all).
    ///
    /// R7-review fix (Important-1): `reformIfProvisional: false`, deliberately — UNLIKE
    /// `formNetworkSnapshot`, this path must stay strictly idempotent against a PROVISIONAL existing
    /// snapshot too. It is reached from a broadcast-bearing read (`migrationNetworkOptions`); a
    /// mid-run call landing here (the BG-executor lane this safety net exists for in the first place)
    /// must return the SAME endpoint/Tor choice a prior read already handed out, never a fresh draw —
    /// re-rolling here would break R7's "made at migration start and held for the run."
    private func ensureNetworkSnapshot(accountUUID: AccountUUID?) async -> MigrationNetworkSnapshot {
        await ensureOrCreateNetworkSnapshot(accountUUID: accountUUID, stampCommitted: true, reformIfProvisional: false)
    }

    /// Idempotent ensure-or-create for `accountUUID`'s (resolved, if `nil`, to the selected account)
    /// atomic per-run network snapshot — shared body for `formNetworkSnapshot` (provisional,
    /// `stampCommitted: false`, `reformIfProvisional: true`) and `ensureNetworkSnapshot` (safety net,
    /// `stampCommitted: true`, `reformIfProvisional: false`). Returns the persisted snapshot when one
    /// already exists AND (it is already COMMITTED, or `reformIfProvisional` is false) — an existing
    /// snapshot's committed state is never promoted by this method, only by
    /// `markNetworkSnapshotCommitted`. Otherwise creates one from the CURRENT sync endpoint/Tor
    /// choice and persists it (stamped committed or left provisional per `stampCommitted`), REPLACING
    /// a stale existing PROVISIONAL snapshot when `reformIfProvisional` is true (see
    /// `formNetworkSnapshot`'s doc for why that's always safe pre-broadcast). A missing/unresolvable
    /// account still returns SOME snapshot (the current endpoint/Tor choice, unpersisted) — every
    /// path ends in a value, never a throw.
    ///
    /// MOB-1497 (R9-T6, finding 8): no `transactionGuard` acquisition here any more — see
    /// `migrationNetworkOptions`'s doc for why forming never needed it. `createNetworkSnapshot()`
    /// (the only `await` this needs — endpoint/Tor-flag/random-pick reads) runs unguarded, OUTSIDE
    /// any lock; the race that used to require a guard's double-check-after-acquire (two concurrent
    /// callers for the SAME account both observing "no reusable snapshot" above, both computing a
    /// candidate) is now closed at the storage layer — `MigrationSnapshotStorage.ensureOrCreate`
    /// re-checks the SAME reuse condition against whatever is ACTUALLY persisted at the instant its
    /// `PerAccountCodableStorage` lock is held, and returns whichever value wins (a concurrent
    /// former's already-persisted write if it satisfies the condition, this call's own candidate
    /// otherwise) — so the value returned here always matches what is actually stored, never a value
    /// some other racing call has already superseded.
    private func ensureOrCreateNetworkSnapshot(
        accountUUID: AccountUUID?,
        stampCommitted: Bool,
        reformIfProvisional: Bool
    ) async -> MigrationNetworkSnapshot {
        let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id

        if let resolvedAccountUUID,
           let existing = snapshotStorage.snapshot(for: resolvedAccountUUID),
           existing.committedAt != nil || !reformIfProvisional {
            return existing
        }

        var candidate = await createNetworkSnapshot()
        if stampCommitted {
            candidate.committedAt = Date()
        }

        guard let resolvedAccountUUID else {
            return candidate
        }

        return snapshotStorage.ensureOrCreate(candidate: candidate, reformIfProvisional: reformIfProvisional, for: resolvedAccountUUID)
    }

    /// MOB-1497 (R9-T3, C1 fix): see `MigrationManagerClient.isSyncServerIdentityCustom`'s doc.
    /// Deliberately a SEPARATE, tiny computation from `createNetworkSnapshot` below rather than a
    /// shared extraction — that function's `syncProvider` local is read a SECOND time later (the
    /// broadcast-candidate filter), so factoring out just the `isCustomServer` half would mean
    /// either reshaping its control flow or returning an unused value to this caller; this few-line
    /// duplication keeps that already-reviewed, privacy-sensitive function untouched.
    func isSyncServerIdentityCustom() -> Bool {
        if case ServerProvider.custom = ServerProvider.classify(host: zcashSDKEnvironment.endpoint().host) {
            return true
        }
        return false
    }

    /// The actual read+random-pick sequence for a fresh snapshot — see
    /// `ensureOrCreateNetworkSnapshot`'s doc for the caller that awaits this (MOB-1497 R9-T6:
    /// unguarded — this runs BEFORE the atomic storage decide-and-write, never inside it). Never
    /// throws; every path ends in a snapshot, always freshly PROVISIONAL (`committedAt == nil` — the
    /// caller stamps it when `stampCommitted` is set). MOB-1497 (R7): makes ZERO network calls — no
    /// benchmark, no clearnet pre-probe.
    private func createNetworkSnapshot() async -> MigrationNetworkSnapshot {
        let currentEndpoint = zcashSDKEnvironment.endpoint()
        let useTor = gateStorage.isTorEnabledForMigration()
        let syncProvider = ServerProvider.classify(host: currentEndpoint.host)

        // MOB-1497 (R8): identity-based ONLY — the stored `ServerConfig.isCustom` flag no longer
        // drives migration routing (it keeps its non-migration uses, e.g. `ServerSetupStore`'s own
        // "Custom" picker state). A manually-entered host that resolves to a known provider's
        // infrastructure (e.g. `eu.zec.rocks`) is that provider, full stop — only a host that
        // classifies as `.custom` BY IDENTITY is treated as custom.
        var isCustomServer = false
        if case ServerProvider.custom = syncProvider {
            isCustomServer = true
        }

        let broadcastEndpoint: LightWalletEndpoint

        if isCustomServer {
            // Michal's rule: a user-selected custom server is used for ALL operations — sync and
            // every migration broadcast — no separation.
            broadcastEndpoint = currentEndpoint
        } else {
            let network = zcashSDKEnvironment.network().networkType
            let candidates = ZcashSDKEnvironment.endpoints(for: network, skipDefault: false).filter { candidate in
                let candidateProvider = ServerProvider.classify(host: candidate.host)
                guard candidateProvider != syncProvider else { return false }
                if case ServerProvider.custom = candidateProvider { return false }
                return true
            }

            if candidates.isEmpty {
                // Testnet (single endpoint), or defensively no other-family built-in host at all —
                // same-server fallback (the sanctioned single-server mode extends here too).
                broadcastEndpoint = currentEndpoint
            } else {
                // MOB-1497 (R7): uniform-random pick across the OTHER provider's shipped endpoints —
                // replaces the old `evaluateBestOf` benchmark entirely. Snapshot creation must make
                // ZERO network calls (the benchmark's clearnet pre-probe was itself a privacy leak
                // while Tor is on) and must not select by proximity/latency/locale — either would
                // carry a hint about the user's region that the Tor circuit otherwise conceals — so a
                // uniform index draw over the full candidate set satisfies both at once.
                let index = migrationRandomness.randomIndex(candidates.count)
                broadcastEndpoint = candidates[index]
            }
        }

        // MOB-1497 (R2 data half / R8 consequence): a custom server can't be reached over Tor — force
        // the formed snapshot's `useTor` false for a custom sync provider, regardless of the stored
        // pre-run choice. T2's sheet UI disables/hides the toggle for a custom user, but the stored
        // choice could in principle still read `true` (e.g. the app-wide Tor flag) — this is the
        // data-layer belt to that UI belt, since this is the value background broadcasts actually
        // read.
        let effectiveUseTor = isCustomServer ? false : useTor

        // R8-T3 (#22): `syncProvider`/`broadcastProvider` are computed on `MigrationNetworkSnapshot`
        // now (from `syncEndpoint`/`broadcastEndpoint`'s own hosts) — no longer constructor args.
        return MigrationNetworkSnapshot(
            useTor: effectiveUseTor,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(currentEndpoint),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(broadcastEndpoint),
            takenAt: Date()
        )
    }

    /// MOB-1496 (W3): called from Root's sync-completion edge (`RootInitialization.swift`'s
    /// `.synchronizerStateChanged`, the false->true transition into `.upToDate` — the same edge
    /// `reconcile()` fires on) so this updates once per completed sync, never per tick.
    func recordSyncCompleted() {
        MigrationTrace.recordSyncCompleted()
        // R13 Brick 1: sync finishing is a WRITER edge — the wallet store just advanced, so every
        // wallet-derived snapshot fact (greens, pool values, `asOfSyncedAt`) may have moved. This
        // edge is exactly the one the old world could miss: a sync that mines a transfer without
        // flipping `MigrationState` never fired `stateEvents`, and the 30-second pulse was the
        // patch. Republish every observed account.
        snapshotSubjects.withLock { Array($0.keys) }.forEach { scheduleSnapshotRepublish(for: $0) }
    }

    /// MOB-1496 (R8-T4, #3): backing continuation for `migrationSyncGateFeed()` — see
    /// `MigrationManagerClient.migrationSyncGateFeed`'s doc for the full mechanism this feeds.
    /// `migrationSyncGateFeed()` hands back a FRESH `AsyncStream` (and continuation) on every call,
    /// retaining only the MOST RECENT continuation here — exactly what `Root
    /// .registerForSynchronizersUpdate`'s own `cancellable(id: state.migrationSyncGateCancelId,
    /// cancelInFlight: true)` needs, since that subscription (SDK stream + this feed, merged) is
    /// cancelled and re-established as one unit every time the action re-fires, so only ONE
    /// subscriber is ever meaningfully "live" at a time.
    private let migrationSyncGateContinuation = OSAllocatedUnfairLock<AsyncStream<Bool>.Continuation?>(initialState: nil)

    /// MOB-1496 (R8-T4, #3): see `MigrationManagerClient.migrationSyncGateFeed`'s doc.
    func migrationSyncGateFeed() -> AsyncStream<Bool> {
        AsyncStream<Bool> { continuation in
            migrationSyncGateContinuation.withLock { $0 = continuation }
            // SELF-HEALING SEED (audit 2026-08-03, #9): a `refreshMigrationSyncGate()` nudge that
            // lands between the old subscription's teardown and THIS continuation's install is a
            // silent no-op — and the nudge sites are exactly the broadcast-failure recovery paths
            // that already stopped sync, so one lost yield used to strand sync for the session.
            // Every fresh subscription therefore re-reads the gate and yields the answer itself:
            // whatever a dropped nudge would have said is subsumed by this read.
            Task { [sdkSynchronizer] in
                continuation.yield(await sdkSynchronizer.isMigrationSyncBlocked())
            }
        }
    }

    /// MOB-1496 (R8-T4, #3): read+yield only — see `MigrationManagerClient.refreshMigrationSyncGate`'s
    /// doc. Deliberately outside `serialExecutor` (mutates none of this class's own persisted state —
    /// the continuation box is throwaway plumbing, not app state) and never touches `transactionGuard`
    /// (not a broadcast/server-switch).
    func refreshMigrationSyncGate() async {
        let isBlocked = await sdkSynchronizer.isMigrationSyncBlocked()
        _ = migrationSyncGateContinuation.withLock { $0?.yield(isBlocked) }
    }

    /// Re-reads `getMigrationState` for EVERY candidate account (R8-T3 #17 — was selected + first
    /// Keystone account only, per the doc this replaces; a Keystone-selected wallet never
    /// reconciled its software account's stale schedule/snapshot, pinning auto-selection and
    /// arming the ServerSetup warning indefinitely). The account set is
    /// `MigrationDerivations.candidateAccountUUIDs` (selected first, then the rest of
    /// `walletAccounts`, deduped) — the SAME source `activeNetworkSnapshots()`/
    /// `resetPersistedFlags()` now also use (R8-T3: those two previously hand-rolled their own
    /// account lists, which disagreed with each other and with this one on order/dedupe). Pushes
    /// each account into its `stateEvents` subject on either a state or balance-to-migrate change
    /// (MOB-1496 W2 emit-fix — see `pushStateIfChanged`'s doc).
    ///
    /// Also runs the stale-acknowledge reset, now PER-ACCOUNT (R8-T3 S2 — the flag itself used to
    /// be wallet-wide, so only the selected account's reset made sense; now every account resets
    /// its OWN flag): an account's acknowledged flag must never suppress a *new* migration's
    /// completion banner for THAT account (reinstall, Path F, or a second logical run after
    /// "Migrate anyway") — only meaningful while ITS OWN state is `.complete`.
    ///
    /// R8-T3 (#24): `orchardBalanceToMigrate` is backed by a full-wallet `getAccountsBalances()`
    /// read — the pre-fix loop called it once PER account (N accounts -> N identical full-wallet
    /// computations per pass). Hoisted to ONE read above the loop, indexed per account below.
    ///
    /// R8-T3 (#18): each account's read-state -> decide -> clear span runs under `serialExecutor`.
    /// The pre-fix version read state, suspended on the balance read, then tested that STALE state
    /// against a FRESHLY-read `hasStoredPayload` — a schedule committed DURING the suspension (the
    /// no-split commit lane deliberately doesn't stop sync) could be wiped by a reconcile pass that
    /// started before the commit but finished after it. Serializing the whole span against
    /// `recordCommittedSchedule`/`acknowledgeComplete`/`clearAbandonedNetworkSnapshot` closes the
    /// window: whichever gets the executor first runs to completion (including its own storage
    /// write) before the other can begin. Called on every foreground entry / launch
    /// (`RootInitialization.swift`) and after a store reports a completed migration op
    /// (`MigrationSendingStore`/`MigrationNoteSplitStore`).
    ///
    /// MOB-1496: also runs the once-per-completion-transition migration-remainder evaluation —
    /// `MigrationState.complete` is per-RUN now (the stored run is fully mined), never "nothing
    /// left to migrate," so an account freshly observed `.complete` with no remainder verdict yet
    /// (`remainderPending(for:) == nil`) gets ONE `evaluateMigrationRemainder` call. See that
    /// method's doc for why this must not run on every pass. Leaving `.complete` clears the verdict
    /// (`clearRemainderPending`, right beside the existing acknowledge-clear below) so the NEXT
    /// completion of a later run gets its own fresh evaluation.
    /// PHASE 4 (D9): arm the next window's pokes. NEW code, not #1930's — its arming lived in the
    /// BG scheduler's session outcomes, which D2 deleted.
    ///
    /// Height -> date is an ESTIMATE (`MigrationETA.minutesFromNow`), and that is fine here: these
    /// are advisory pokes, and every broadcast decision is still made against the engine's own
    /// height-based due-ness at open (the CRANK is the sole authority — matrix D7: a poke can only
    /// bring the user back, never sanction a send, and only a `.broadcast` step does that). An
    /// early poke therefore causes no broadcast, only a calm "not yet".
    /// Arms THE notification — exactly one per account, always.
    ///
    /// The migration has no background lane. Nothing happens unless the user opens Zodl, and each
    /// open is one opportunity to take ONE step: sync, or send, or split, or re-plan. Which one
    /// depends on state at open time, so the poke names none of them.
    ///
    /// One step per open is the PRIVACY property, not a convenience: a sync and a send should not
    /// be adjacent enough for an observer to link them. 2026-08-07: what enforces that is the
    /// one-step-per-open shape itself plus the engine's own scheduling, NOT a timer — the ~600 s
    /// post-sync buffer this used to name was deleted, because a fixed delay is exactly the kind of
    /// regular pattern an observer keys on. So after any step there is still exactly one moment
    /// worth poking about: when the NEXT step becomes due.
    ///
    /// This replaces the D9 two-poke cadence (a `timeToSync` lead ahead of a `manualTransferReady`
    /// at the window). That pair assumed the user would open at a time we chose; they do not —
    /// they are asleep, at work, in a cinema. The lead poke was therefore usually spent on nobody,
    /// and it doubled the volume of a flow whose whole appeal is that it asks little. It also made
    /// D13 ("suppress the sync poke when a sync already happened") an unsolvable problem, since a
    /// scheduled local notification cannot be conditionally withdrawn at delivery time. With one
    /// poke, armed fresh on every open, there is nothing to suppress.
    ///
    /// Content-generic rather than account-specific on purpose: two accounts migrating at once
    /// still means one app to open, and a poke that named an account would have to promise which
    /// one still needs attention by the time it fires. It cannot.
    ///
    /// P3: the poke is armed at the earliest moment the run has ANY step to take, which is not
    /// always the next transfer's window. The engine schedules its own sync/proving wake-ups
    /// (`migrationSyncWakeups`), and those come FIRST by construction: proving is what makes a
    /// broadcast window usable at all. Poking only at the broadcast window meant the user could
    /// arrive exactly on time and find the transfer unproven — the crank answers `.prove` rather
    /// than `.broadcast`, nothing is sent, and the run waits for whenever they happen to open the
    /// app next. Heights become dates through the measured block rate (`MigrationChainClock`),
    /// not a 75 s assumption, and are re-drawn on every call: the engine re-jitters its wake-ups per
    /// read, so this must never cache a schedule.
    func armNextWindowNotifications(accountUUID: AccountUUID?, outlook: MigrationNextWork? = nil) async {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }

        let clock = await chainClock(accountUUID: resolvedAccountUUID)
        let now = Date()

        // A SYNC step: the earliest height at which the engine wants the wallet woken and proved.
        // No privacy buffer applies — a sync visit is the thing THAT buffer separates a SEND from.
        // The two-block notification slack does apply; see `MigrationChainClock.notificationBuffer`.
        let proveDate = (try? await sdkSynchronizer.migrationSyncWakeups(resolvedAccountUUID))?
            .map { clock.notificationDate(atHeight: $0.height, now: now) }
            .min()

        // A SEND step: the earliest row still needing a broadcast — across BOTH row lists.
        //
        // MOB-1466 (N1, field-caught 2026-08-01). This read `migrationTransfers` alone, which
        // filters to `.transfer`-kind statuses: a note-split PREPARATION contributed nothing to the
        // poke. `migrationSyncWakeups`' own doc spells the contract out — register wake-ups from
        // those heights "plus each status row's `scheduledHeight` for the broadcast windows" — and
        // we were doing the first half and a subset of the second.
        //
        // What that cost, from the device: with the run in `splitPendingConfirmation`, the arm
        // predicted `prove 17:50:27, send 17:51:41` while preparation 0's window was ALREADY open
        // at 17:33. Worse than a miss — the `send` date it did compute was the first TRANSFER's
        // window, and no transfer can go until the preparations mine, so the arm predicted an event
        // that could not happen and missed the one that could. The run only moved because the user
        // opened the app manually, out of curiosity. On iOS with no background lane, a window
        // nobody is poked about is a window that goes unused.
        //
        // `!isBroadcasting` on top of `status != .sent`: a row already on the wire needs no send
        // window. Without it the arm treats a broadcast-but-unmined row as "next to send", whose
        // ETA has by definition passed, and schedules a poke one notification-buffer later for
        // work that is already done.
        let transferRows = await migrationTransfers(accountUUID: resolvedAccountUUID)
        let statuses = (try? await sdkSynchronizer.migrationTransactionStatuses(resolvedAccountUUID)) ?? []
        let preparationRows = MigrationDerivations.preparationRows(statuses: statuses, clock: clock) ?? []
        // R11: `.confirming` excluded alongside `.sent` — a confirming row is on the chain's side
        // (broadcast or already mined, wallet not yet synced), so it needs no send window either;
        // counting it would schedule an imminent poke for work that is already done.
        // E2E harness F#1 (2026-08-04): `.invalid`/`.expired` excluded too — a dead row cannot be
        // sent, so arming its "window" (whose ETA has by definition passed → an imminent poke,
        // re-armed forever) promises an action that cannot exist. The needsUser blocker candidate
        // below (#13) is the honest poke for that state: generic "come back" copy, no window claim.
        let pendingBroadcast = (preparationRows + transferRows)
            .filter {
                $0.status != MigrationTransferRow.Status.sent
                && $0.status != MigrationTransferRow.Status.confirming
                && $0.status != MigrationTransferRow.Status.invalid
                && $0.status != MigrationTransferRow.Status.expired
                && !$0.isBroadcasting
            }
            // MOB-1466: an unknown ETA sorts LAST. `nil` means "cannot answer", and letting it
            // compare as 0 would make the least-known row win the soonest-row pick.
            .min { ($0.forwardETAMinutes ?? Int.max) < ($1.forwardETAMinutes ?? Int.max) }

        var sendDate: Date?
        if let next = pendingBroadcast {
            // ...at its own window. 2026-08-07: the post-sync privacy-buffer clamp that used to
            // push this out is gone with the buffer itself — a poke now points at the moment the
            // send actually becomes due, with nothing timed standing between a sync and it.
            //
            // The row carries MINUTES (its displayed ETA), not a height, so the two-block slack is
            // added here rather than through `notificationDate` — same number, same reason.
            // MOB-1466: with an unknown tip there is no ETA to arm from — `forwardETAMinutes` is
            // `nil`, and arming off a fabricated zero would schedule the poke for "now". Fall back
            // to the row's coarse position estimate, which never consults a tip.
            sendDate = now.addingTimeInterval(
                TimeInterval(next.forwardETAMinutes ?? next.hoursFromNow * 60) * 60 + clock.notificationBuffer
            )
        }

        let accountHex = Data(resolvedAccountUUID.id).hexEncodedString()
        // Audit 2026-08-03 (#13): a `.needsUser`-blocked run has no prove or send window of its
        // own, so both dates read nil and the no-pending branch below would retire the poke —
        // leaving a backgrounded wallet with NO armed mechanism to learn it is waiting on the
        // user (a Keystone rebuild's ceremony, attention needing a re-plan, stalled proving).
        // The blocker contributes a near-term candidate instead; the poke's copy is deliberately
        // generic ("no number, no account — a promise the app might not keep"), which is exactly
        // right for "come back, the run needs you".
        let blockerDate: Date? = stepBlockerAccounts.withLock { $0.contains(resolvedAccountUUID) }
            ? now.addingTimeInterval(60)
            : nil

        // P4 (outlook adoption, #2936): the engine's own "when is the next serviceable step"
        // answer — one step of lookahead from the SAME advance read that drove this session's
        // discharge (the driver passes it through; feature callers have no fresh read in hand and
        // pass nothing — re-reading here is off the table, the advance read is a write-lane pass).
        // Min-folded below: the outlook can only make the poke earlier, never later, and the
        // authorities it augments — `migrationSyncWakeups`, the row windows — keep their say.
        let outlookDate = MigrationDerivations.outlookCandidateDate(
            outlook: outlook,
            clock: clock,
            now: now
        )
        guard let nextStepDate = [proveDate, sendDate, blockerDate, outlookDate].compactMap({ $0 }).min() else {
            // Nothing left to do — retire THIS ACCOUNT's poke rather than leaving a stale one
            // armed. Scoped (audit 2026-08-03, P1): the wallet-wide sweep this used to be erased
            // the OTHER account's just-armed poke on every per-account arming pass — the
            // account with nothing pending wiped everything and armed nothing.
            MigrationTrace.notificationCancelled("no prove wake-up, no unsent row, no blocker and no outlook")
            await userNotifications.cancelMigrationNotifications(accountHex)
            return
        }

        // Cancel first, then arm — scoped to this account: "exactly one PER ACCOUNT, never more".
        // Re-posting the same identifier would replace its own kind; the scoped sweep also retires
        // the un-suffixed `timeToSync` an older build may have left pending, without touching a
        // sibling account's armed poke.
        await userNotifications.cancelMigrationNotifications(accountHex)
        await userNotifications.scheduleMigrationNotification(
            MigrationNotification.stepReady,
            nextStepDate,
            Data(resolvedAccountUUID.id).hexEncodedString()
        )

        // WHEN, and WHICH of the four candidates won. A poke is the one part of this lane the user
        // meets while the app is closed, so "did it arm, and for when" cannot be answered by
        // watching the app — and §7 of the scenario sheet is untestable without it. Every candidate
        // date is printed, not just the winner: a poke firing at the wrong moment is almost
        // always another candidate having been the one that mattered.
        // Authorization, every time. A denied/undetermined status makes every arm below a silent
        // no-op, and that is the first thing to check when a poke never arrives.
        let authorization = await userNotifications.authorizationStatus()
        if authorization != .authorized {
            LoggerProxy.event("\(Self.logTag) notification: authorization is \(authorization) — NOTHING will be delivered")
        }

        let inSeconds = Int(nextStepDate.timeIntervalSince(now).rounded())
        // E2E harness F#1 (2026-08-04): the blocker candidate used to read "send window" here —
        // the trace itself lied about which poke was armed.
        let source: String
        if nextStepDate == proveDate {
            source = "prove wake-up"
        } else if nextStepDate == sendDate {
            source = "send window"
        } else if nextStepDate == outlookDate {
            source = "engine outlook (\(outlook.map { String(describing: $0.kind) } ?? "?"))"
        } else {
            source = "attention blocker"
        }
        // MOB-1466: remembered ACROSS sessions, so the next app-open can say whether it was manual,
        // on schedule, or late relative to this poke — see `MigrationTrace.pokeRelation`.
        MigrationTrace.notificationArmed(at: nextStepDate, source: source)
        LoggerProxy.event(
            "\(Self.logTag) notification ARMED for \(nextStepDate) (in \(inSeconds)s) — \(source)"
            + "; prove \(proveDate.map(String.init(describing:)) ?? "none")"
            + ", send \(sendDate.map(String.init(describing:)) ?? "none")"
            + ", blocker \(blockerDate.map(String.init(describing:)) ?? "none")"
            + ", outlook \(outlookDate.map(String.init(describing:)) ?? "none")"
            + "; buffer \(Int(clock.notificationBuffer))s at \(Int(clock.secondsPerBlock))s/block"
        )
    }

    /// See `MigrationManagerClient.visitKind`. Reads every candidate account's advance step and
    /// lets `MigrationVisit.decide` make the wallet-wide call.
    ///
    /// Reads run concurrently and a per-account failure contributes `nil` (no vote) rather than
    /// aborting: one account's engine error must not decide the whole wallet's session type.
    func visitKind() async -> MigrationVisit {
        guard isIronwoodActivated() else { return .sync }

        let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: selectedWalletAccount?.id,
            walletAccounts: walletAccounts
        )
        guard !accountUUIDs.isEmpty else { return .sync }

        // AUD-3: decided PER ACCOUNT and OR-ed — transfer ids are per-run, so two accounts can
        // both own id 3 and a pooled id set would misclassify. A due PREPARATION broadcast keeps
        // the visit `.sync` (ZIP-exempt — see `MigrationVisit`'s header); only TRANSFER dueness
        // suppresses sync for the open.
        var visit = MigrationVisit.sync
        for accountUUID in accountUUIDs {
            let step = (try? await sdkSynchronizer.migrationAdvanceStep(accountUUID))?.step
            // THE key driver, logged verbatim. Everything this lane does follows from the engine's
            // answer here, and until 07-31 it was the one thing never written down: a run sitting at
            // 0-of-12 looked identical whether the engine was saying `prove`, `waiting`, or
            // `broadcast`, so "nothing is happening" could not be told from "the engine is asking
            // for something nobody does".
            LoggerProxy.event("\(Self.logTag) advance step: \(step.map { String(describing: $0) } ?? "none (no run)")")

            var preparationIds: Set<UInt32> = []
            if case MigrationAdvanceStep.broadcast? = step {
                preparationIds = await preparationTransactionIds(accountUUID: accountUUID)
            }
            if MigrationVisit.decide(advanceSteps: [step], preparationIds: preparationIds) == MigrationVisit.send {
                visit = MigrationVisit.send
            } else if case let MigrationAdvanceStep.broadcast(instruction)? = step, preparationIds.contains(instruction.id) {
                LoggerProxy.event(
                    "\(Self.logTag) preparation \(instruction.id) due — ZIP-exempt, the session stays a sync session (AUD-3)"
                )
            }
        }
        if visit == .send {
            LoggerProxy.event("\(Self.logTag) broadcast due — this session will NOT sync")
        }
        return visit
    }

    /// AUD-3: the ids of `accountUUID`'s note-PREPARATION transactions, from the same statuses
    /// read every surface uses. ZIP 318 scopes the sync/broadcast separation and the post-sync
    /// buffer to TRANSFERS ("a preparation transaction is a fully shielded send-to-self"), so
    /// every kind-aware policy site (the visit, the plan's afterSync cell, the mode belt, the
    /// manual-delivery hold, the send gate) keys off this set. A failed read degrades to the
    /// EMPTY set — i.e. to the conservative transfer treatment, never to an over-eager send.
    func preparationTransactionIds(accountUUID: AccountUUID) async -> Set<UInt32> {
        let statuses = (try? await sdkSynchronizer.migrationTransactionStatuses(accountUUID)) ?? []
        return Set(
            statuses.compactMap { status in
                if case MigrationTransactionStatus.Kind.preparation = status.kind {
                    return status.id
                }
                return nil
            }
        )
    }

    /// THE PROVE EXECUTOR for ONE account — see `MigrationManagerClient.runProveSweep`.
    ///
    /// PER-ACCOUNT AND INSTRUCTION-TAKING (2026-08-07). This used to be account-agnostic: it
    /// re-derived the candidate set itself and called a payload-free wallet-wide sweep once per
    /// account. That shape does not survive the SDK's instruction executors —
    /// `proveMigrationTransactions` proves the rows THIS batch names, and a batch belongs to the
    /// account whose crank produced it. Sweeping accounts a second time in here would prove
    /// un-instructed; the driver already iterates accounts and holds each one's advance, so it
    /// passes both the account and its own batch.
    ///
    /// `maxProofs` is the caller's budget, chosen by PHASE rather than fixed: each proof is
    /// seconds of CPU, and a 30 s tick should take on less than a post-sync edge. A skipped row
    /// (already proved, anchor unresolvable) does not spend the budget, so a `0` return is still
    /// the ordinary "nothing in this batch is provable right now" answer.
    ///
    /// Deliberately OUTSIDE `serialExecutor`: proving is a long, purely additive engine operation
    /// (it stores proofs; it mutates no app-side migration storage), and holding the mutex that
    /// serializes reconcile/commit for its whole duration would stall the very reconcile that is
    /// about to run behind it. A failure degrades to 0 rather than throwing — the next sync visit
    /// retries.
    func runProveSweep(
        accountUUID: AccountUUID,
        instruction: [MigrationProveTarget],
        maxProofs: Int
    ) async -> MigrationProveOutcome {
        let nothingProved = MigrationProveOutcome(totalProved: 0, preparationTxids: [])
        guard isIronwoodActivated() else { return nothingProved }
        guard !instruction.isEmpty else { return nothingProved }

        let accountUUIDs = [accountUUID]

        setMigrationWorkInFlight(true)
        defer { setMigrationWorkInFlight(false) }

        pokeStateEvent(for: accountUUID)

        var outcome = nothingProved
        do {
            outcome = try await sdkSynchronizer.proveMigrationTransactions(accountUUID, instruction, maxProofs)
        } catch {
            // Includes `migrationProvingUnavailable` (ZRUST0127), the one HARD proving error:
            // the ironwood tree is not queryable yet. Nothing the app can do but try at the
            // next sync visit, so log and carry on.
            LoggerProxy.event("\(Self.logTag) prove pass failed: \(error.toZcashError())")
        }
        // Logged even at ZERO. A sweep that proves nothing, over and over, while the engine keeps
        // asking to prove IS the signal — and staying quiet about it made a stalled run look
        // identical to a healthy idle one.
        let proved = outcome.totalProved
        MigrationTrace.recordProveSweep(proved: proved)
        let preparations = outcome.preparationTxids.count
        LoggerProxy.event(
            "\(Self.logTag) prove pass: proved \(proved) of \(instruction.count) instructed, \(preparations) preparation(s) to submit"
        )
        if proved == 0 {
            let anyRowClaimedProvable = await logProveStall(accountUUIDs: accountUUIDs)
            // A FRUITLESS sweep is not the same as a quiet one. A sweep that proves nothing because
            // nothing was ready is correct and expected; a sweep that proves nothing while the
            // engine is reporting rows as ready-to-prove is a CONTRADICTION, and the user pays for
            // it in a "Keep Zodl open" ask they cannot satisfy.
            //
            // Field-caught 2026-08-02, overnight run: every one of twelve transfers reported
            // `blocked -` (nil, i.e. actionable) with anchors ~800 blocks BEHIND the scanned tip,
            // and the sweep proved zero. The app asked the user to sit and watch, indefinitely,
            // while nothing could move. §8 of SMART_BANNER_STATES asked whether `.preparing` should
            // ever time out; the field has now answered yes.
            if anyRowClaimedProvable {
                let fruitless = fruitlessProveSweeps.withLock { count -> Int in
                    count += 1
                    return count
                }
                if fruitless == Self.fruitlessSweepsBeforeStalled {
                    LoggerProxy.event(
                        "\(Self.logTag) 🛑 PROVE STALLED — \(fruitless) sweeps proved nothing while rows report ready-to-prove."
                        + " Dropping the keep-open ask: staying in the app does not help."
                    )
                }
            } else {
                fruitlessProveSweeps.withLock { $0 = 0 }
            }
        } else {
            fruitlessProveSweeps.withLock { $0 = 0 }
        }
        // Post-sweep republish: the proofs this sweep persisted are the news; with the
        // serve-stale layer gone, the builds these pokes trigger read them directly.
        for accountUUID in accountUUIDs {
            pokeStateEvent(for: accountUUID)
        }
        return outcome
    }

    /// Consecutive prove sweeps that produced nothing WHILE the engine reported rows as
    /// ready-to-prove. Reset by any successful proof, and by a sweep that correctly found nothing
    /// ready. In-memory: a fresh app-open gets one honest attempt before the app is willing to call
    /// proving stalled.
    private let fruitlessProveSweeps = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Two, not one. A single fruitless sweep can be a race — the statuses were read after the
    /// sweep started, or a proof landed between the two reads. Two in a row on the same app-open is
    /// the engine telling us the same impossible thing twice.
    private static let fruitlessSweepsBeforeStalled = 2

    /// See `fruitlessProveSweeps`. Read by the row derivations to suppress the "Preparing
    /// transaction…" caption and its spinner, and so — through the rows — the `.preparing` banner
    /// and its "Keep Zodl open" ask.
    ///
    /// The rule this enforces: THE APP MAY ONLY ASK THE USER TO STAY FOR WORK THAT IS ACTUALLY
    /// HAPPENING. A spinner over work that has demonstrably stopped is worse than no spinner at
    /// all — it spends the credibility every future keep-open ask depends on.
    var isProvingStalled: Bool {
        fruitlessProveSweeps.withLock { $0 } >= Self.fruitlessSweepsBeforeStalled
    }

    /// WHY a sweep proved nothing, in the app's own log.
    ///
    /// The engine does explain itself — `prove_due_transaction` emits a `deferred (transient)`
    /// warning naming the exact prover error — but that line goes to the Rust `tracing` → os_log
    /// bridge (subsystem `co.electriccoin.ios`, category `rust`), NOT through `LoggerProxy`, so it
    /// never reaches the stream anyone reads while testing. Field-caught 2026-08-01: a run sat at
    /// 0-of-12 for a day with `prove sweep: proved 0` next to `advance step: prove(transactions: …)` and
    /// nothing anywhere naming the reason.
    ///
    /// The three heights are the reading, and they separate the two candidate causes without
    /// another build:
    ///
    /// - `anchor <= scanned` — the wallet HAS scanned the boundary, so failing to prove there
    ///   means the checkpoint is gone (retention/pruning) or the note is not witnessable at it.
    /// - `scanned < anchor <= tip` — the engine judged the boundary settled against the CHAIN
    ///   tip while the wallet has not scanned that far. Upstream's `next_step` is documented as
    ///   taking `scanned_tip + 1` ("must rest on data the wallet has actually seen"), and a
    ///   transfer's anchor-boundary settledness is judged on the scanned target ALONE — so this
    ///   reading means proving can never succeed, however often it is retried.
    ///
    /// Only at `proved == 0`, and only the first few non-mined rows: a healthy sweep says nothing
    /// extra, and a 12-transfer run must not turn one stall into twelve log lines.
    /// Returns whether ANY non-mined row reported itself ready-to-prove — the other half of the
    /// stall verdict (see `fruitlessProveSweeps`). Reading it here reuses the status fetch this
    /// function already makes rather than paying for a second one.
    @discardableResult
    private func logProveStall(accountUUIDs: [AccountUUID]) async -> Bool {
        let syncState = sdkSynchronizer.latestState()
        let estimatedTip = try? await sdkSynchronizer.estimatedMigrationChainTip()

        var anyRowClaimedProvable = false
        for accountUUID in accountUUIDs {
            guard let rows = try? await sdkSynchronizer.migrationTransactionStatuses(accountUUID), !rows.isEmpty else {
                continue
            }
            if rows.contains(where: { $0.isReady && $0.nextAction == MigrationTransactionStatus.NextAction.prove }) {
                anyRowClaimedProvable = true
            }

            let pending = rows
                .filter { row in
                    if case MigrationTransactionStatus.State.mined = row.state { return false }
                    return true
                }
                .prefix(3)
                .map { row in
                    let anchor = row.anchorBoundaryHeight.map(String.init) ?? "none"
                    let blocked = row.blockedOn.map { String(describing: $0) } ?? "-"
                    return "#\(row.id) \(row.state) anchor \(anchor) sched \(row.scheduledHeight) blocked \(blocked)"
                }
                .joined(separator: " | ")
            guard !pending.isEmpty else { continue }

            LoggerProxy.event(
                """
                \(Self.logTag) prove stall: scanned \(syncState.fullyScannedHeight), \
                chain tip \(syncState.latestBlockHeight), \
                est \(estimatedTip.map(String.init) ?? "n/a") — \(pending)
                """
            )
        }
        return anyRowClaimedProvable
    }

    /// See `MigrationManagerClient.migrationChainClock` — the public face of `chainClock`, with the
    /// selected-account fallback every `nil`-accepting member here uses.
    func migrationChainClock(accountUUID: AccountUUID?) async -> MigrationChainClock {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return MigrationChainClock.unknown }
        return await chainClock(accountUUID: resolvedAccountUUID)
    }

    /// THE BROADCAST SESSION — see `MigrationManagerClient.runBroadcastSession`.
    ///
    /// Follows `MigrationSendingStore.executeNextTransfer`'s ENGINE lane step for step (stop sync,
    /// read the run's pinned network snapshot, submit against the estimated tip, classify, record,
    /// reconcile, reopen the gate) and diverges in exactly one way, which is the whole reason both
    /// exist: this lane has NO SCREEN. There is no failure sheet to present and no Retry to offer,
    /// so a classified failure is routed for its PERSISTENT effects only — the Tor-hold indicator
    /// and the pending-prompt latch, i.e. the state the banner and the flow read on the next
    /// visit — and the returned route is dropped. Nothing here presents, alerts, or navigates.
    ///
    /// Deliberately OUTSIDE `serialExecutor`, same reasoning as `runProveSweep`: a submission is a
    /// long network operation (Tor bootstrap included), and holding the mutex that serializes
    /// reconcile/commit across it would block the very `reconcile()` that runs at the end of it.
    /// `vettedAccountUUID` (audit 2026-08-03, #4): the driver's discharge is PER-ACCOUNT — its
    /// mode belt and manual-delivery checks vet one account's step, then this session used to
    /// re-sweep EVERY candidate itself, selected-first, and could submit for exactly the account
    /// the belt had just held (an `.immediate` account's due transfer delivered off a tick). The
    /// driver now passes the account it vetted and the session delivers THAT one; the wallet-wide
    /// sweep remains for the parameterless client member (no production caller today).
    /// `vettedPreparationDelivery` (AUD-3): the driver vetted this session's id as a note-
    /// PREPARATION. It used to skip two holds here — the post-sync privacy buffer and the
    /// manual-delivery contract — and both of those are gone now (the manual-tap surface on
    /// 2026-08-07 with the send lane, the buffer the same day as an identifiable pattern). What it
    /// still decides is the BANNER MAP below: a prep submit wears keep-open, never "Transfer N is
    /// sending". The submit itself is unchanged — same artifact handout, same outcome
    /// verification, same `mark_broadcast` recording.
    func runBroadcastSession(
        accountUUID: AccountUUID,
        instruction: MigrationBroadcastInstruction,
        vettedPreparationDelivery: Bool = false
    ) async -> Bool {
        guard isIronwoodActivated() else { return false }

        // MOB-1466 (N2) held this lane for a fixed window after the last COMPLETED sync. That
        // hold is GONE (2026-08-07): a fixed sync->broadcast delay is an identifiable pattern in
        // its own right — the same reasoning that deleted the SDK's post-broadcast buffer — so
        // pacing by the clock is no longer how either direction of the adjacency is handled.
        // Sequencing still is: `broadcastOneTransfer` stops a running sync before it submits, and
        // the SDK refuses a start while its own submission is in flight. A live sync is therefore
        // only worth a note here, never a refusal — refusing on it would let an unrelated
        // background sync stall a run indefinitely.
        if sdkSynchronizer.isSyncing() {
            LoggerProxy.event("\(Self.logTag) broadcast proceeding with a sync in flight — it will be stopped first")
        }

        // THE INSTRUCTION IS THE AUTHORITY (2026-08-07). This lane used to decide for itself what
        // was deliverable: it cranked the engine a SECOND time (the driver had already cranked),
        // took the scanned-frame step's id, and — when that was quiet — fell back to the AUD-1
        // one-clock tiebreaker, synthesising a delivery out of `hasOverdueMigrationTransfers` plus
        // a queue peek. All of it is gone. The driver cranked once, and the instruction it hands
        // down IS the sanction; there is nothing left here to re-derive or second-guess, and no
        // second clock to reconcile (the crank applies the estimate itself now). The submit still
        // has the last word: a stale instruction draws the seam's staleness throw, which
        // `broadcastOneTransfer` discharges by asking for a fresh crank rather than retrying.
        let id = instruction.id

        // Re-entrancy: a driver call arriving while this account is already mid-broadcast (a
        // second foreground trigger, a raced scene-phase flip) must not submit twice.
        guard broadcastsInFlight.withLock({ $0.insert(accountUUID).inserted }) else { return false }

        MigrationTrace.recordBroadcast()
        LoggerProxy.event("\(Self.logTag) broadcasting migration tx \(id) — headless send session")
        // D6: the id THIS session submits — the banner renders it, never a row-inferred guess.
        activeBroadcastTxIds.withLock { $0[accountUUID] = id }
        if vettedPreparationDelivery {
            // THE BANNER MAP: a prep submit wears keep-open, never "Transfer N is sending".
            preparationBroadcastsInFlight.withLock { _ = $0.insert(accountUUID) }
        }

        setMigrationWorkInFlight(true)

        pokeStateEvent(for: accountUUID)
        let didBroadcast = await broadcastOneTransfer(accountUUID: accountUUID, instruction: instruction)
        // Cleared BEFORE the closing poke, so that one derives fresh — it is the edge that
        // reveals the row this broadcast just changed.
        setMigrationWorkInFlight(false)
        broadcastsInFlight.withLock { _ = $0.remove(accountUUID) }
        activeBroadcastTxIds.withLock { $0[accountUUID] = nil }
        preparationBroadcastsInFlight.withLock { _ = $0.remove(accountUUID) }
        pokeStateEvent(for: accountUUID)

        // ZIP 318: a session carries ONE broadcast ATTEMPT. The RETURN is the attempt's real
        // outcome (audit 2026-08-03, #5): this used to be an unconditional `true`, so a rejected
        // result and a thrown submit both read as "broadcast" upstream — the driver logged
        // `.broadcast(id:)` on every open, forever, while nothing went out.
        return didBroadcast
    }

    /// One account's submission, from `runBroadcastSession`. Every exit path either ends in a
    /// landed broadcast (the SDK's own migration gate transitions, and nothing needs nudging) or
    /// reopens the app-side sync gate — sync was stopped for a broadcast that did not land, and
    /// without the nudge nothing else would ever restart it.
    ///
    /// Returns whether a broadcast actually LANDED (a `.success` result, or the
    /// landed-but-record-failed shape, which is a landed broadcast by definition).
    private func broadcastOneTransfer(accountUUID: AccountUUID, instruction: MigrationBroadcastInstruction) async -> Bool {
        let options = await migrationNetworkOptions(accountUUID: accountUUID)
        await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()

        do {
            // Straight-line now (2026-08-07). The executor takes the crank's own instruction and
            // returns the recorded result — no tip parameter (the conduit projected the estimate
            // once, at the crank) and no outcome cases to disambiguate. The two arms that used to
            // live here are both gone by construction: `.nothingDue` cannot arise when an
            // instruction is in hand, and a due-but-unproved row now reaches the app as a `.prove`
            // batch entry rather than as a delivery outcome.
            let result = try await sdkSynchronizer.performMigrationBroadcast(accountUUID, instruction, options)

            if let failureClass = MigrationBroadcastFailureClass.classify(result: result) {
                _ = await routeBroadcastFailure(accountUUID: accountUUID, failureClass: failureClass)
            }
            LoggerProxy.event("\(Self.logTag) broadcast result: \(result)")
            await recordTransferBroadcast(accountUUID: accountUUID, result: result)
            await reconcile()
            guard case MigrationTransferResult.success = result else {
                await refreshMigrationSyncGate()
                return false
            }
            return true
        } catch ZcashError.rustMigrationTakeBroadcastTransaction {
            // THE STALE INSTRUCTION. The row this instruction named is no longer
            // proved-and-servable — typically because it was already broadcast, or a tip moved
            // under us between the crank and the submit. Nothing was sent.
            //
            // The discharge is to CRANK AGAIN, never to retry the executor: retrying re-presents
            // the same dead instruction, while a fresh crank returns whatever the run actually
            // needs now (possibly a different step kind entirely). This lane does not crank
            // itself — it reopens the sync gate and returns false, exactly as the old
            // `.nothingDue` arm did, and the driver's next pass gets a fresh instruction.
            LoggerProxy.event(
                "\(Self.logTag) broadcast instruction \(instruction.id) went stale before the submit — cranking again, not retrying"
            )
            await refreshMigrationSyncGate()
            return false
        } catch ZcashError.migrationRecordFailedAfterBroadcast {
            // The broadcast LANDED and only recording it failed (the engine self-heals later) —
            // treated exactly as a success: not a failure to route, and no gate nudge.
            await reconcile()
            return true
        } catch {
            if let failureClass = MigrationBroadcastFailureClass.classify(error: error) {
                _ = await routeBroadcastFailure(accountUUID: accountUUID, failureClass: failureClass)
            }
            LoggerProxy.event("\(Self.logTag) headless broadcast failed — \(error.toZcashError())")
            await refreshMigrationSyncGate()
            return false
        }
    }

    /// THE PREP-SUBMIT MARKER WINDOW. Brackets ONE self-submitted preparation's submit-to-record
    /// span with the same in-flight markers `runBroadcastSession` sets around a delivery —
    /// `broadcastsInFlight`, the D6 `activeBroadcastTxIds` id, the AUD-3 keep-open banner map
    /// (`preparationBroadcastsInFlight` — always: this window serves preparations only), and
    /// `setMigrationWorkInFlight` — poked into the state stream on entry and again after the
    /// clears, in that session's own order.
    ///
    /// The driver's prove pass submits proved preparations ITSELF (`submitProvedPreparations` —
    /// the ordinary path, deliberately not a delivery ceremony), and without these markers the app
    /// READ IDLE while a preparation's bytes were on the wire: `isPreparationBroadcastInFlight`
    /// and `isBroadcastInFlight` both false, so no keep-open/"splitting balance" banner, and the
    /// re-entry route's `isMigrationWorkInFlight` short-circuit never engaged — a user who
    /// backgrounded or killed the app mid-broadcast stalled the split until a later pass re-proved
    /// it. The markers are set BEFORE the bytes can reach the wire and cleared on EVERY exit —
    /// success, failure and throw alike (the `defer` covers the throwing paths).
    ///
    /// Returns `nil`, WITHOUT invoking `body`, when the account is already mid-broadcast — the
    /// same `broadcastsInFlight` re-entrancy guard `runBroadcastSession` takes, so a preparation
    /// submit can never overlap a transfer's delivery (or another prep submit) for the same
    /// account. The caller skips the row; the engine re-offers it on its next crank.
    func withPreparationBroadcastMarkers<T>(
        accountUUID: AccountUUID,
        id: UInt32,
        _ body: () async throws -> T
    ) async rethrows -> T? {
        guard broadcastsInFlight.withLock({ $0.insert(accountUUID).inserted }) else { return nil }
        activeBroadcastTxIds.withLock { $0[accountUUID] = id }
        preparationBroadcastsInFlight.withLock { _ = $0.insert(accountUUID) }
        setMigrationWorkInFlight(true)
        pokeStateEvent(for: accountUUID)
        defer {
            // Cleared BEFORE the closing poke, so that one derives fresh — it is the edge that
            // reveals what this submission just changed. Same order as `runBroadcastSession`.
            setMigrationWorkInFlight(false)
            broadcastsInFlight.withLock { _ = $0.remove(accountUUID) }
            activeBroadcastTxIds.withLock { $0[accountUUID] = nil }
            preparationBroadcastsInFlight.withLock { _ = $0.remove(accountUUID) }
            pokeStateEvent(for: accountUUID)
        }
        return try await body()
    }

    func reconcile() async {
        guard isIronwoodActivated() else { return }

        let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: selectedWalletAccount?.id,
            walletAccounts: walletAccounts
        )
        guard !accountUUIDs.isEmpty else { return }

        // R8-T3 (#24): ONE full-wallet balances computation for the whole pass — see this method's
        // doc. A throw degrades to `nil`, which `reconcileOrchardBalance` below reads as `.zero` per
        // account (same degrade-on-error precedent `orchardBalanceToMigrate` already follows).
        let walletBalances = try? await sdkSynchronizer.getAccountsBalances()

        for accountUUID in accountUUIDs {
            await serialExecutor.run { [self] in
                guard let state = await migrationState(accountUUID: accountUUID) else { return }

                let hasBalanceToMigrate = reconcileOrchardBalance(from: walletBalances, accountUUID: accountUUID) > Zatoshi.zero
                pushStateIfChanged(state, hasBalanceToMigrate: hasBalanceToMigrate, for: accountUUID)

                if state != MigrationState.complete {
                    gateStorage.clearAcknowledgedComplete(for: accountUUID)
                    // MOB-1496: leaving `.complete` invalidates any remainder verdict from the run
                    // that just ended — the next time this account reaches `.complete` (this run
                    // continuing, or a later one) must be evaluated fresh, not inherit a stale flag.
                    gateStorage.clearRemainderPending(for: accountUUID)
                } else if gateStorage.remainderPending(for: accountUUID) == nil {
                    // MOB-1496: evaluate EXACTLY ONCE per completion transition — see
                    // `evaluateMigrationRemainder`'s doc for the plan-cache hazard that makes a
                    // per-reconcile re-propose unsafe. Already-evaluated (true OR false) accounts
                    // skip straight past this, regardless of how many more reconciles run before
                    // the account eventually leaves `.complete`.
                    //
                    // MOB-1513 (H3 guard): the gate above gets this call down to once per
                    // transition, but says nothing about WHEN that one call may land — a migration
                    // screen for this SAME account may be mid-review of an uncommitted propose
                    // right now (see `evaluateMigrationRemainder`'s doc for the exact hazard). Skip
                    // the WHOLE branch (evaluate AND its paired rounds increment) while that's true
                    // for this account — neither `remainderPending` nor `completedRounds` update
                    // this pass, so they stay paired; the account is left exactly as if this pass
                    // had never observed the transition, and the NEXT reconcile pass (there are
                    // many call sites) retries once the flow closes. Delayed, never lost.
                    if !isMigrationFlowPresented(accountUUID: accountUUID) {
                        // MOB-1511 (W2): the completed-rounds counter rides the SAME exactly-once
                        // gate — one increment per run completion, however many reconciles observe
                        // it. BEHIND the evaluation's persistence (audit 2026-08-03, #14): the
                        // increment used to run FIRST, so a thrown propose — which persists
                        // nothing precisely so the next pass retries — left the branch re-enterable
                        // with the increment already taken: one completed run, N+1 rounds,
                        // permanently ("Round 4 of 2" labels). Now the retry re-runs the WHOLE
                        // pair, and the counter moves only when the evaluation actually latched.
                        if await evaluateMigrationRemainder(for: accountUUID) {
                            gateStorage.incrementCompletedRounds(for: accountUUID)
                        }
                    }
                }

                // MOB-1496 (W2): a run abandoned/reset out from under a stale persisted schedule —
                // the engine is authoritative, so `.notStarted` observed against an account that
                // still has a stored payload means that payload no longer corresponds to anything
                // the engine knows about (e.g. a debug reset, or a fresh install reusing a restored
                // seed). MOB-1496 (W4): the network snapshot's lifetime is tied to the same logical
                // run as the schedule payload — clear it beside the schedule (a later dust mini-run
                // then takes a FRESH snapshot, which is correct).
                // MOB-1497: `clearIfCommitted`, not the unconditional `clear` — this is a BACKGROUND
                // reconcile tick, which can race a user sitting on the Tor sheet/plan screen with
                // state still `.notStarted` and a just-formed PROVISIONAL snapshot (forming now
                // happens at the Tor-choice step, before any schedule is committed). Wiping that
                // snapshot out from under them mid-flow is exactly the hazard this guards against; a
                // committed snapshot still clears here exactly as before. Provisional snapshots are
                // cleared only by flow teardown (`clearProvisionalNetworkSnapshot`) or promoted to
                // committed (`markNetworkSnapshotCommitted`).
                if state == MigrationState.notStarted && scheduleStorage.hasStoredPayload(for: accountUUID) {
                    scheduleStorage.clear(for: accountUUID)
                    snapshotStorage.clearIfCommitted(for: accountUUID)
                    // MOB-1497 (R7-T3): the had-broadcast flag/episode's lifetime is tied to the
                    // same logical run as the schedule payload — clear beside it (a later dust
                    // mini-run then starts first-run-fresh, matching the snapshot's precedent).
                    failureRoutingStorage.clear(for: accountUUID)
                }
            }
        }
    }

    /// MOB-1496: asks the engine directly whether anything remains for `accountUUID` beyond the run
    /// that just reached `.complete` — a fresh, non-committing `proposeMigrationTransfers(_:)`;
    /// an empty schedule means genuinely done, a non-empty one means more remains (surfaced via
    /// `bannerVariant`'s `.complete` arm as `MigrationBannerVariant.required`, and via the BG
    /// session's `handleLandedBroadcast` as a `.migrationBatchComplete` notification instead of
    /// `.migrationComplete`).
    ///
    /// CRITICAL — why `reconcile()`'s caller only invokes this ONCE per completion transition
    /// (gated on `remainderPending(for:) == nil`), never on every reconcile pass:
    /// `proposeMigrationTransfers` OVERWRITES the SDK's own plan cache, and a later commit must
    /// match the LATEST propose. If this ran again while the user were mid-review of an EARLIER
    /// propose from this same evaluation (e.g. deciding on the Migration Complete screen whether to
    /// migrate a residual), that in-flight plan would be invalidated out from under them and its
    /// eventual commit would fail with `migrationPlanStale`. Gating on the persisted tri-state flag
    /// (`nil` = never evaluated since the last non-`.complete` state) makes this call genuinely
    /// once-per-transition regardless of how many more times `reconcile()` itself runs before the
    /// account eventually leaves `.complete` again.
    ///
    /// On a THROW, persists NOTHING — the flag is left `nil` so a LATER reconcile pass retries
    /// (self-healing: a transient propose failure must not wrongly freeze the flag at a stale
    /// value, and must not be mistaken for "evaluated, genuinely nothing pending").
    ///
    /// MOB-1513 (H3, guarded): the "once per transition" gate above is confirmed — this is called
    /// ONLY when `state == .complete` AND `remainderPending(for:) == nil`, never on every
    /// `reconcile()` pass. But `reconcile()` itself is called from many, unrelated places —
    /// `RootInitialization.swift` (foreground entry, `.retryStart`, the BG session's
    /// `handleLandedBroadcast`, `.migrationSyncGateChanged`), `MigrationCoordFlowCoordinator.swift`
    /// (right after a schedule/note-split store, ×3), `MigrationCommitPipeline.swift`,
    /// `MigrationSendingStore.swift`, `MigrationNoteSplitStore.swift` — none of which know whether
    /// SOME OTHER account's flow currently has an uncommitted `proposeMigrationTransfers` result on
    /// screen. `reconcile()` walks EVERY candidate account each time it runs, so the one guaranteed
    /// call this gate allows could land while the user is reviewing a plan for the SAME account that
    /// reached `.complete` — e.g. "Migrate Anyway" (`MigrationCoordFlowCoordinator.migrateAnyway`/
    /// `MigrationComplete`'s `dustResolution`), whose visibility is driven by `migrationSummary`'s
    /// OWN independent residual read (`scheduleStorage`/`residualAfterMigration`), NOT by this
    /// method's `remainderPending` flag — so a user can reach and act on that screen (kicking off
    /// its OWN fresh propose) before this evaluation has run even once. If BOTH proposes were in
    /// flight for the same account, whichever landed second would win the SDK's plan cache and the
    /// other's eventual commit would fail `migrationPlanStale`.
    ///
    /// GUARDED now: `reconcile()`'s caller (see the call site above) skips this entire branch —
    /// including the paired `completedRounds` increment — while `isMigrationFlowPresented
    /// (accountUUID:)` reads `true` for this account. That signal is armed by
    /// `MigrationCoordFlowCoordinator.onAppear`'s genuine-flow-start branch
    /// (`state.path.isEmpty`) and disarmed by every production close/replace site for
    /// `Root.State.Path.migrationCoordFlow` — see `presentedFlowAccountUUIDs`'s doc for the full,
    /// verified list (it ended up being FOUR sites, not three: `RootCoordinator
    /// .tearDownMigrationCoordFlow`, shared by `.flowFinished`/`.switchServerRequested`/the inline
    /// `.home(.walletAccountTapped)` teardown; `RootCoordinator`'s `.sending(.delegate
    /// (.viewTransaction))` case, which closes the path WITHOUT routing through that helper; and
    /// `RootInitialization.openMigrationCoordFlow`, which can wholesale-replace
    /// `migrationCoordFlowState` while the flow is already open). A skip never loses the
    /// evaluation — `remainderPending` stays `nil` (un-evaluated), so the NEXT `reconcile()` pass
    /// (there are many call sites) retries once the flag clears: delayed, never lost. Missing a
    /// disarm site would leave the flag stuck `true` forever, permanently blocking this account's
    /// remainder evaluation — worse than the race this guard closes — which is why every site above
    /// was verified against HEAD rather than assumed from the three the original (unguarded) version
    /// of this doc named.
    /// Returns whether the evaluation PERSISTED its answer — `false` on a thrown propose, which
    /// deliberately leaves `remainderPending` nil so a later pass retries. The caller's paired
    /// rounds increment keys off this (audit 2026-08-03, #14).
    @discardableResult
    private func evaluateMigrationRemainder(for accountUUID: AccountUUID) async -> Bool {
        guard let schedule = try? await sdkSynchronizer.proposeMigrationTransfers(accountUUID) else { return false }
        gateStorage.setRemainderPending(!schedule.transfers.isEmpty, for: accountUUID)
        return true
    }

    /// MOB-1511 (W2): the round context the multi-round labels render — the CURRENT round number
    /// (completed runs + 1, app-persisted) plus the engine's estimated TOTAL round count
    /// (`SDKSynchronizerClient.estimateMigrationRunCount`'s doc), `nil` when the estimate has zero
    /// runs. Re-fetched fresh on every call rather than cached — see that member's doc for why the
    /// total is a preview that can shift with the balance, not a persisted fact.
    func migrationRoundContext(accountUUID: AccountUUID?) async -> (round: Int, totalRounds: Int?) {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return (1, nil) }
        let round = gateStorage.completedRounds(for: resolvedAccountUUID) + 1
        let totalRounds = (try? await sdkSynchronizer.estimateMigrationRunCount(resolvedAccountUUID)) ?? nil
        return (round, totalRounds)
    }

    /// D14: how many "Split Balance" rows the PRE-commit plan shows — the engine's estimated
    /// preparation-transaction count for the NEXT run. `1` whenever the estimate is unavailable, so
    /// an estimate failure degrades to exactly the single row every plan showed before D14 rather
    /// than to no split row at all. Clamped to at least 1 for the same reason: a run that reaches
    /// the plan screen always splits at least once.
    func migrationPreparationCount(accountUUID: AccountUUID?) async -> Int {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return 1 }
        let estimate = (try? await sdkSynchronizer.estimateMigrationPreparationCount(resolvedAccountUUID)) ?? nil
        return max(1, estimate ?? 1)
    }

    /// D14: the POST-commit "Split Balance" rows, from the run's REAL `.preparation`-kind statuses —
    /// so a multi-transaction split shows each transaction with its own state and ETA instead of one
    /// summary row. `nil` when the statuses carry no preparation at all (no run stored yet, or a
    /// read failure), which tells the caller to fall back to its synthesized single row.
    func migrationPreparationRows(accountUUID: AccountUUID?) async -> [MigrationTransferRow]? {
        await migrationPreparationRowsComputing(accountUUID: accountUUID)
    }

    private func migrationPreparationRowsComputing(accountUUID: AccountUUID?) async -> [MigrationTransferRow]? {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return nil }
        let statuses = (try? await sdkSynchronizer.migrationTransactionStatuses(resolvedAccountUUID)) ?? []
        return MigrationDerivations.preparationRows(
            statuses: statuses,
            clock: await chainClock(accountUUID: resolvedAccountUUID),
            isProvingStalled: isProvingStalled,
            confirmedTxIds: await walletMinedTxIds(accountUUID: resolvedAccountUUID),
            rememberedTxIds: rememberBroadcastTxIds(from: statuses, accountUUID: resolvedAccountUUID)
        )
    }

    /// A14: the "Prepare Your Balance" sheet's real per-step ladder — see
    /// `MigrationDerivations.prepareBalanceRows`. Sibling of `migrationPreparationRows` above: same
    /// source statuses, different renderer (the sheet's step list rather than the timeline's rows).
    func migrationPrepareBalanceRows(accountUUID: AccountUUID?) async -> [MigrationPrepareBalanceRow]? {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return nil }
        let statuses = (try? await sdkSynchronizer.migrationTransactionStatuses(resolvedAccountUUID)) ?? []
        return MigrationDerivations.prepareBalanceRows(
            statuses: statuses,
            clock: await chainClock(accountUUID: resolvedAccountUUID),
            // THE SPINNER INVARIANT: the sheet takes the same stall verdict as the timeline rows
            // and the banner — one verdict, three quiet surfaces.
            isProvingStalled: isProvingStalled
        )
    }

    /// R8-T3 (#24): per-account lookup against `reconcile()`'s ONE hoisted `getAccountsBalances()`
    /// read — mirrors `orchardBalanceToMigrate`'s own derivation without re-issuing the full-wallet
    /// read itself.
    private func reconcileOrchardBalance(from walletBalances: [AccountUUID: AccountBalance]?, accountUUID: AccountUUID) -> Zatoshi {
        guard let balance = walletBalances?[accountUUID] else { return .zero }
        // MOB-1496 (W-D): same locked-exclusion as `orchardBalanceToMigrate` above — a "Lock
        // balance" transition must never re-flip `hasBalanceToMigrate` from false to true.
        return balance.orchardBalance.unlockedForMigration
    }

    /// R8-T3 (V18 + S2): reads `accountUUID`'s (resolved, if `nil`, to the selected account) engine
    /// state FRESH and NO-OPs (logging a warning) unless it is EXACTLY `.complete` — nothing is
    /// cleared otherwise. Pre-fix this was unconditional: the immediate-mode Sending close called
    /// it while the engine was still genuinely `.inProgress` (completion needs mined-confirmed AND
    /// `orchard_spendable == 0`, not merely "the last transfer broadcast succeeded"), wiping the
    /// very schedule/snapshot records the still-live run needed — `reconcile()` then cleared the
    /// (wrongly-set) acknowledged flag on its next pass, so the completion UX resurfaced hydrated
    /// from the now-wiped storage (a "0 transferred" fallback).
    ///
    /// On a genuine `.complete` read: sets the PER-ACCOUNT acknowledged flag (R8-T3 S2 — was
    /// wallet-wide, which suppressed every OTHER account's own completion banner/re-entry the
    /// moment ONE account acknowledged, made that other account's own `acknowledgeComplete`
    /// unreachable, and left its snapshot immortal) and clears `accountUUID`'s schedule + snapshot
    /// — the run the Complete screen was showing has ended, so its committed schedule/sent
    /// records/network snapshot must not leak into a future run's rows (a fresh migration, e.g. a
    /// later "Migrate anyway" dust mini-run, starts from an empty logical run + a FRESH snapshot).
    ///
    /// R8-T3 (#18): the whole read-state -> decide -> clear span runs under `serialExecutor` so it
    /// can never interleave with a concurrent `recordCommittedSchedule`/`reconcile`/
    /// `clearAbandonedNetworkSnapshot` for the SAME account.
    func acknowledgeComplete(accountUUID: AccountUUID?) async {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }

        await serialExecutor.run { [self] in
            guard let state = await migrationState(accountUUID: resolvedAccountUUID), state == MigrationState.complete else {
                LoggerProxy.warn(
                    "[MigrationManagerImpl] acknowledgeComplete no-op — account state is not .complete."
                )
                return
            }

            gateStorage.acknowledgeComplete(for: resolvedAccountUUID)
            scheduleStorage.clear(for: resolvedAccountUUID)
            snapshotStorage.clear(for: resolvedAccountUUID)
            // MOB-1497 (R7-T3): the failure-routing state (had-broadcast flag + R16 episode)
            // shares the run's lifetime — clear it with the run's other records.
            failureRoutingStorage.clear(for: resolvedAccountUUID)
        }
    }

    /// R8-T3 (#9): a confirm lane that fails/is abandoned BEFORE ever committing a schedule still
    /// took its network snapshot on the FIRST `migrationNetworkOptions` read (every lane does, well
    /// before any store/broadcast) — every automatic clear requires `.notStarted &&
    /// hasStoredPayload` (this account never had a payload) or an acknowledge (nothing completed,
    /// so it's never reached) — so an abandoned pre-commit run leaked an ACTIVE snapshot forever
    /// (`UserDefaults`, no TTL), pinning auto-server-selection and arming the ServerSetup privacy
    /// warning indefinitely. Reads `accountUUID`'s engine state FRESH — `.notStarted` with no
    /// stored schedule payload means nothing was ever committed this attempt (or the run genuinely
    /// finished/reset already) — clears its snapshot; any other state (a real active/committed run)
    /// is a no-op. R8-T3 (#18): serialized alongside `reconcile`/`recordCommittedSchedule`/
    /// `acknowledgeComplete` for the same TOCTOU reasons. Deliberately self-contained (doesn't reach
    /// for anything a real run's schedule/state would carry) so the R7 branch's provisional-snapshot
    /// machinery can subsume it on rebase.
    ///
    /// Two sanctioned production call sites (R9-T5, finding 7 — the fix that added the second one):
    /// (1) the coordinator's `.flowFinished` handler (`RootCoordinator.swift`, every flow-root close
    /// / terminal delegate), fire-and-forget for the selected account only (`nil` resolves it, same
    /// convention as `migrationSummary`/`recordCommittedSchedule` above) — covers a flow closed out
    /// normally without committing. (2) app launch, via `RootInitialization.swift`'s
    /// `.clearAbandonedMigrationSnapshots` action — sent from TWO points there (final-review
    /// IMPORTANT-1), since accounts aren't necessarily in state yet at the first one:
    /// `.initialSetups`'s reconcile-chained send (covers a WARM re-init, where accounts are already
    /// populated from earlier in the same process) and `.loadedWalletAccounts`'s send (the one that
    /// actually fires on a genuine COLD launch, once the SDK's own account list lands in state and
    /// the SDK is provably prepared). Both routes fan over EVERY candidate account
    /// (`MigrationDerivations.candidateAccountUUIDs`), never `nil` — covers a flow abandoned by
    /// killing the app mid-run, which never reaches `.flowFinished` at all, for whichever account
    /// (not necessarily the selected one) was mid-flow at kill time. All three call sites share the
    /// SAME guard on the migration flow not being open before ever calling this (see
    /// `.clearAbandonedMigrationSnapshots`'s reducer arm) — this function itself stays unaware of
    /// any of them.
    func clearAbandonedNetworkSnapshot(accountUUID: AccountUUID?) async {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }

        await serialExecutor.run { [self] in
            guard let state = await migrationState(accountUUID: resolvedAccountUUID) else { return }
            guard state == MigrationState.notStarted, !scheduleStorage.hasStoredPayload(for: resolvedAccountUUID) else { return }
            guard snapshotStorage.snapshot(for: resolvedAccountUUID) != nil else { return }

            LoggerProxy.event("[MigrationManagerImpl] Clearing an abandoned pre-commit network snapshot.")
            snapshotStorage.clear(for: resolvedAccountUUID)
        }
    }

    /// R8-T3: reads `accountUUID`'s per-account acknowledged flag (`nil` resolves the selected
    /// account, same convention as the other members here; a genuinely unresolvable account reads
    /// as un-acknowledged rather than crashing).
    func isCompleteAcknowledged(accountUUID: AccountUUID?) -> Bool {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return false }
        return gateStorage.isCompleteAcknowledged(for: resolvedAccountUUID)
    }

    /// MOB-1496: reads `accountUUID`'s persisted remainder flag (`nil` resolves the selected
    /// account, same convention as `isCompleteAcknowledged` above; a genuinely unresolvable account
    /// reads as `false` rather than crashing). The tri-state `nil` (never evaluated since the last
    /// completion transition) is flattened to `false` HERE, at the client-facing boundary — the
    /// storage layer (`MigrationGateStorage.remainderPending(for:)`) keeps the raw `Bool?` so
    /// `reconcile()` can tell "never evaluated" apart from "evaluated, genuinely empty." See
    /// `evaluateMigrationRemainder`'s doc for how/when the flag actually gets set.
    func isMigrationRemainderPending(accountUUID: AccountUUID?) -> Bool {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return false }
        return gateStorage.remainderPending(for: resolvedAccountUUID) ?? false
    }

    /// MOB-1513 (H3 guard): arms/disarms `accountUUID`'s entry in `presentedFlowAccountUUIDs` — see
    /// that property's doc for the full production call-site list. `nil` is a no-op either
    /// direction: there is no account to key the signal to, and every caller already resolves the
    /// concrete account it means before calling — this never falls back to `selectedWalletAccount`
    /// (doing so could silently arm/disarm the WRONG account's signal during an in-flight account
    /// switch, which is exactly the stranding hazard this guard exists to avoid).
    func setMigrationFlowPresented(accountUUID: AccountUUID?, isPresented: Bool) {
        guard let resolvedAccountUUID = accountUUID else { return }
        presentedFlowAccountUUIDs.withLock { accountUUIDs in
            if isPresented {
                accountUUIDs.insert(resolvedAccountUUID)
            } else {
                accountUUIDs.remove(resolvedAccountUUID)
            }
        }
    }

    /// MOB-1513 (H3 guard): reads whether `accountUUID` currently has a propose-consuming migration
    /// screen on screen — see `presentedFlowAccountUUIDs`'s doc. `reconcile()`'s own gate (below)
    /// is the one production reader; exposed (not `private`) so tests can round-trip the flag
    /// directly against the impl, mirroring `isTorHoldActive`'s precedent.
    func isMigrationFlowPresented(accountUUID: AccountUUID) -> Bool {
        presentedFlowAccountUUIDs.withLock { $0.contains(accountUUID) }
    }

    /// Test-only "Reset app migration flags" reset — the migration simulator debug panel that used
    /// to call this was removed (MOB-1458); today it's exercised solely by `MigrationManagerTests`/
    /// `MigrationFailureRoutingTests`.
    /// MOB-1496 (W2): also clears every candidate account's persisted schedule — a reset must
    /// leave no stale committed-schedule payload behind either. MOB-1496 (W4): and its network
    /// snapshot; MOB-1497 (R7-T3): and its failure-routing state (had-broadcast flag + R16
    /// episode). R8-T3: sourced from `MigrationDerivations.candidateAccountUUIDs` (was two separate
    /// hand-rolled loops — `walletAccounts`, then `selectedWalletAccount` again, redundantly
    /// re-clearing it — that disagreed with `reconcile()`'s/`activeNetworkSnapshots()`'s own
    /// account-set logic); also now clears each candidate account's own per-account acknowledged
    /// flag (R8-T3 S2 — the flag itself used to be wallet-wide, cleared directly by
    /// `gateStorage.resetPersistedFlags()` alone). MOB-1496: also clears each candidate account's
    /// own per-account remainder verdict — same rationale as the acknowledged flag, since a reset
    /// must leave no stale "more to migrate" verdict behind either.
    /// THE WALLET-RESET WIPE (MOB-1466 N3, field-caught 2026-08-01): every scheduled migration
    /// notification cancelled, every persisted migration key removed, every in-session flag
    /// dropped. Called from Root's `.resetZashiSDKSucceeded`, alongside
    /// `clearDeviceScopedWalletState`, and it belongs to the same rule that helper states in its own
    /// comments: nothing from the previous owner of this device survives the reset boundary.
    ///
    /// The field report is the whole argument. Reset the wallet, restore a fresh one — and a
    /// notification armed by the wallet that no longer exists fires, inviting the user into a
    /// migration run that is not theirs. Every step after that tap reads state keyed to a wallet
    /// that was deleted.
    ///
    /// Deliberately NOT folded into `resetPersistedFlags()` above, which is a different and much
    /// narrower thing (a test-only flags reset, four keys, and it leaves the sync-completed stamp
    /// alone on purpose). Conflating them would have made the debug reset silently start cancelling
    /// notifications too.
    func wipeAllMigrationState() async {
        MigrationTrace.notificationCancelled("wallet reset")
        // `nil` scope — the wallet reset is the one caller that genuinely means EVERY account.
        await userNotifications.cancelMigrationNotifications(nil)
        gateStorage.wipeEverything()
        broadcastsInFlight.withLock { $0.removeAll() }
        // Audit 2026-08-03 (#19): the wipe used to clear the rows cache (since retired — Q2-1) and
        // broadcastsInFlight and leave every sibling map behind — a same-seed restore (same
        // AccountUUIDs) could then be served the PREVIOUS wallet's banner from the work-in-flight
        // cache path, and the other holdovers survived into the next wallet's process lifetime for
        // no reason.
        //
        // R13 Brick 2b: `bannerCache` is gone (the published snapshot IS the banner's cache), so
        // the published values are the holdover to clear now — exactly the same same-seed-restore
        // class: push `nil` through live subscriptions (screens fall to their empty states) and
        // drop the subjects; the next subscriber starts from a fresh build of the new wallet.
        snapshotSubjects.withLock { subjects in
            subjects.values.forEach { $0.send(nil) }
            subjects.removeAll()
        }
        snapshotRepublishState.withLock { $0 = ([], []) }
        presentedFlowAccountUUIDs.withLock { $0.removeAll() }
        fruitlessProveSweeps.withLock { $0 = 0 }
        stateSubjects.withLock { $0.removeAll() }
        lastPushedHasBalance.withLock { $0.removeAll() }
        migrationWorkInFlight.withLock { $0 = false }
        stepBlockerAccounts.withLock { $0.removeAll() }
        LoggerProxy.event("\(Self.logTag) wallet reset — notifications cancelled, every migration key wiped")
    }

    func resetPersistedFlags() {
        gateStorage.resetPersistedFlags()
        let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: selectedWalletAccount?.id,
            walletAccounts: walletAccounts
        )
        for accountUUID in accountUUIDs {
            gateStorage.clearAcknowledgedComplete(for: accountUUID)
            gateStorage.clearRemainderPending(for: accountUUID)
            gateStorage.clearMigrationMode(for: accountUUID)
            gateStorage.clearCompletedRounds(for: accountUUID)
            scheduleStorage.clear(for: accountUUID)
            snapshotStorage.clear(for: accountUUID)
            failureRoutingStorage.clear(for: accountUUID)
        }
    }

    /// P3: THE chain-time frame for this account — the SDK's ESTIMATED tip and its MEASURED block
    /// rate, read together so the two halves can never disagree at a call site. See
    /// `MigrationChainClock` for why neither half is the scanned tip or a hardcoded 75 s.
    ///
    /// Each read degrades independently: the tip falls back to the scanned tip (the pre-P3
    /// behaviour, and still a real answer), the rate to Zcash's target spacing. A wallet that has
    /// never scanned a block throws `migrationChainTipUnavailable`, which lands on a scanned tip of
    /// `0` — `MigrationChainClock.unknown`'s "Ready now" flooring, not a fabricated distance.
    private func chainClock(accountUUID: AccountUUID) async -> MigrationChainClock {
        // Addendum §4: both are WALLET-scoped now — the projection reads the shared blocks table,
        // so `accountUUID` only selects the fallback's scanned tip, not the estimate itself.
        async let tipTask = try? await sdkSynchronizer.estimatedMigrationChainTip()
        async let rateTask = try? await sdkSynchronizer.estimatedMigrationSecondsPerBlock()

        let tip = await tipTask ?? sdkSynchronizer.latestState().latestBlockHeight
        let secondsPerBlock = await rateTask ?? MigrationChainClock.targetSecondsPerBlock

        return MigrationChainClock(tip: tip, secondsPerBlock: secondsPerBlock)
    }

    /// MOB-1483: "Ironwood (NU6.3) activated on the current network." `tip > 0` is the fail-safe
    /// sentinel — a cached tip of `0` (before the first server round-trip) is an *unknown* tip, not
    /// a low one, so it must read as "not activated" rather than happening to satisfy `tip >=
    /// activationHeight` by coincidence (mirrors the sentinel idiom in
    /// `SDKSynchronizerClient.transactionStatesFromZcashTransactions`). Not `private`: wired
    /// directly to `MigrationManagerClient.isIronwoodActivated` in `live()`.
    /// Whether the chain is past Ironwood activation.
    ///
    /// LATCHED, because activation is a chain fact and chain facts do not un-happen. The unlatched
    /// version read `latestBlockHeight` fresh every time, and that field is not a tip — it is
    /// whatever this wallet currently believes, which climbs during a sync. Field log, one session:
    ///
    ///     +23.77s no banner: ironwood NOT activated — tip 4090000, activation 4134000
    ///     +25.92s offer gate CLOSED — wallet syncing · height 4234740
    ///
    /// Two seconds apart, same field, 144k blocks. For the first ~26 s the app declared a live
    /// migration impossible on a wallet already 100k blocks past activation.
    ///
    /// Nothing user-visible followed on that path — the Goal-1 sync gate suppresses the offer until
    /// `.upToDate` regardless — so this is not the cause of any reported bug. It is a false statement
    /// the code was making about the chain, on a value that means something else, and the next reader
    /// to depend on it would not get that warning. One observation of `true` is proof; no later
    /// reading can disprove it.
    func isIronwoodActivated() -> Bool {
        if ironwoodActivationSeen.withLock({ $0 }) { return true }
        let tip = sdkSynchronizer.latestState().latestBlockHeight
        let activated = tip > 0 && tip >= zcashSDKEnvironment.ironwoodActivationHeight()
        if activated { ironwoodActivationSeen.withLock { $0 = true } }
        return activated
    }

    /// Set once the chain has been observed past activation — see `isIronwoodActivated`. In-process
    /// only: a fresh launch re-observes it from the first height the synchronizer reports.
    private let ironwoodActivationSeen = OSAllocatedUnfairLock<Bool>(initialState: false)

    // MARK: - MOB-1496: throwing-SDK-read helpers (account-scoped, degrade on error)

    /// The app's lifecycle state, derived from the engine's advance step plus the composable reads
    /// (`MigrationState.derive`) — the SDK stopped handing a state over whole on
    /// `michal/migration-parity-fixes`. `nil` only when the advance-step read itself THROWS; a
    /// healthy account with no run reads a successful `nil` step and derives `.notStarted`.
    ///
    /// The `do`/`catch` is load-bearing and must not be "tidied" back into `try?`. `migrationAdvanceStep`
    /// returns `MigrationAdvance?`, and since SE-0230 `try?` FLATTENS a throwing optional call
    /// into a single optional — so `try? await …` collapses "threw" and "no run" into the same `nil`,
    /// and a `guard let … else { return nil }` on it treats a perfectly healthy no-run account as a
    /// failed read. That is exactly what happened: a freshly restored wallet has no run, so every
    /// `bannerVariant` call returned nil and the migration banner could never appear — which made the
    /// feature's own entry point unreachable, since starting a run is what the banner is FOR.
    /// `MigrationState.derive`'s documented `advanceStep == nil` arm was live-unreachable; only tests
    /// (which pass the optional directly) ever exercised it, which is why 778 of them stayed green.
    private func migrationState(accountUUID: AccountUUID) async -> MigrationState? {
        let advance: MigrationAdvance?
        do {
            advance = try await sdkSynchronizer.migrationAdvanceStep(accountUUID)
        } catch {
            // The read itself failed. Degrade to no state so callers keep their previous value
            // rather than flipping to `.notStarted`.
            LoggerProxy.event("\(Self.logTag) advance-step read FAILED — \(error.toZcashError()); state unknown, keeping previous")
            return nil
        }
        return MigrationState.derive(
            advanceStep: advance?.step,
            progress: try? await sdkSynchronizer.getMigrationProgress(accountUUID),
            statuses: (try? await sdkSynchronizer.migrationTransactionStatuses(accountUUID)) ?? [],
            hasInvalidTransfers: await hasInvalidMigrationTransfers(accountUUID: accountUUID),
            // MOB-1466: read off THIS run's persisted payload, so the marker dies with the run it
            // describes — see `markRunCancelledByUser`.
            wasCancelledByUser: scheduleStorage.wasRunCancelledByUser(for: accountUUID)
        )
    }

    private func migrationProgress(accountUUID: AccountUUID) async -> MigrationProgress? {
        guard let result = try? await sdkSynchronizer.getMigrationProgress(accountUUID) else { return nil }
        return result
    }

    private func hasInvalidMigrationTransfers(accountUUID: AccountUUID) async -> Bool {
        (try? await sdkSynchronizer.hasInvalidMigrationTransfers(accountUUID)) ?? false
    }

    /// `useEstimatedTip` defaults TRUE here: every app-side caller of this helper is asking on a
    /// visit that has not necessarily synced, and a stale scanned tip reports "nothing overdue" for
    /// a transfer that genuinely is. Estimates only accelerate due-ness — expiry and invalidity
    /// still resolve against the scanned tip inside the SDK.
    private func hasOverdueMigrationTransfers(
        accountUUID: AccountUUID,
        useEstimatedTip: Bool = true
    ) async -> Bool {
        (try? await sdkSynchronizer.hasOverdueMigrationTransfers(accountUUID, useEstimatedTip)) ?? false
    }

    // MARK: - MOB-1496: per-account stateEvents subjects

    private func subject(for accountUUID: AccountUUID) -> CurrentValueSubject<MigrationState, Never> {
        stateSubjects.withLock { subjects in
            if let existing = subjects[accountUUID] {
                return existing
            }
            let fresh = CurrentValueSubject<MigrationState, Never>(MigrationState.notStarted)
            subjects[accountUUID] = fresh
            return fresh
        }
    }

    /// MOB-1496 (W2 emit-fix): pushes `state` into the account's subject when EITHER `state` itself
    /// or `hasBalanceToMigrate` changed since the last push — the subject's own `.value` tracks the
    /// last-pushed state; `lastPushedHasBalance` tracks the balance half beside it. A `.send(state)`
    /// still only ever carries `MigrationState` (the subject's declared type never changes), but
    /// firing it on a balance-only flip re-delivers the (unchanged) state value, which is enough to
    /// prompt a subscriber to re-derive its rows/summary/banner off the fresh balance read.
    private func pushStateIfChanged(_ state: MigrationState, hasBalanceToMigrate: Bool, for accountUUID: AccountUUID) {
        // R13 Brick 1: every CALL here is a writer edge — republish the snapshot regardless of
        // whether the coarse state dedupes below. A sync can mine a transfer without changing
        // `MigrationState` at all; the snapshot channel dedupes on VALUE equality instead, so a
        // no-op edge costs one compared build, never a stale screen.
        scheduleSnapshotRepublish(for: accountUUID)

        let subject = subject(for: accountUUID)
        let previousHasBalance = lastPushedHasBalance.withLock { $0[accountUUID] ?? false }

        guard subject.value != state || previousHasBalance != hasBalanceToMigrate else { return }

        lastPushedHasBalance.withLock { $0[accountUUID] = hasBalanceToMigrate }
        subject.send(state)
    }

    /// A13: re-delivers an account's CURRENT state to `stateEvents` subscribers without changing it
    /// — the escape hatch for something that changes what the banner should SAY without changing
    /// the `MigrationState` it derives from. Today that is a broadcast starting and finishing:
    /// `pushStateIfChanged` above would dedupe both, and the banner would keep reading
    /// "Transfer N is waiting" through the whole submission.
    ///
    /// Only pokes a subject that ALREADY exists. `subject(for:)` would create one seeded
    /// `.notStarted`, and subscribers would read that seed as a real state change — closing the
    /// banner instead of refreshing it.
    private func pokeStateEvent(for accountUUID: AccountUUID) {
        // R13 Brick 1: a poke IS a writer edge (broadcast started/finished, reconcile landed) —
        // the snapshot channel republishes on the same signal its subscribers used to requery on.
        scheduleSnapshotRepublish(for: accountUUID)

        guard let subject = stateSubjects.withLock({ $0[accountUUID] }) else { return }
        subject.send(subject.value)
    }

    // MARK: - R13 Brick 1: the published snapshot channel

    /// THE observer entry (GROUND_RULES R13): one loader, one value, every surface. The FIRST
    /// subscription for an account creates its subject (seeded `nil`) and kicks one refresh so the
    /// first real value arrives without waiting for a writer edge. A RE-subscription kicks nothing:
    /// the banner re-arms its stream on every sync-status transition (~15–30 s foregrounded), and a
    /// per-re-arm rebuild would be a continuous background derivation loop — re-subscribing is not
    /// news; writer edges are. Consumers that genuinely want a fresh build on their own schedule
    /// (the status screen's per-open R3 re-verify) call `refreshMigrationSnapshot` explicitly.
    /// Emissions are deduplicated on value equality by the republisher, so a subscriber may render
    /// every emission verbatim.
    func migrationSnapshotEvents(accountUUID: AccountUUID?) -> AnyPublisher<MigrationViewSnapshot?, Never> {
        guard let resolved = accountUUID ?? selectedWalletAccount?.id else {
            return Just(MigrationViewSnapshot?.none).eraseToAnyPublisher()
        }
        let (subject, created) = snapshotSubjects.withLock { subjects -> (CurrentValueSubject<MigrationViewSnapshot?, Never>, Bool) in
            if let existing = subjects[resolved] {
                return (existing, false)
            }
            let fresh = CurrentValueSubject<MigrationViewSnapshot?, Never>(nil)
            subjects[resolved] = fresh
            return (fresh, true)
        }
        if created {
            scheduleSnapshotRepublish(for: resolved)
        }
        return subject.eraseToAnyPublisher()
    }

    /// R13 Brick 2: the PUBLISHED value, synchronously — the status screen's first-frame prime.
    /// A pure read of what the channel last emitted (no derivation, no create), so painting from
    /// it is painting THE source, just before the subscription's first live emission lands. `nil`
    /// when no build has published yet this launch — the screen keeps its ordinary empty state.
    func currentMigrationSnapshot(accountUUID: AccountUUID?) -> MigrationViewSnapshot? {
        guard let resolved = accountUUID ?? selectedWalletAccount?.id else { return nil }
        return snapshotSubjects.withLock { $0[resolved]?.value } ?? nil
    }

    /// R13 Brick 2: a consumer-side refresh request (screen opened, a lane finished) — unlike the
    /// writer-edge hook it CREATES the subject if needed, so an open that beats the subscription's
    /// async setup still gets its build. R3 in channel form: every open re-verifies.
    func refreshMigrationSnapshot(accountUUID: AccountUUID?) {
        guard let resolved = accountUUID ?? selectedWalletAccount?.id else { return }
        snapshotSubjects.withLock { subjects in
            if subjects[resolved] == nil {
                subjects[resolved] = CurrentValueSubject<MigrationViewSnapshot?, Never>(nil)
            }
        }
        scheduleSnapshotRepublish(for: resolved)
    }

    /// The coalesced republisher. No subject → no work (mirrors `pokeStateEvent`'s no-create rule:
    /// republishing for an account nothing observes would be derivation for nobody). A build in
    /// flight absorbs later requests into ONE follow-up build (`dirty`), so a poke burst during a
    /// sweep costs at most two derivations, and the second one sees the sweep's final truth.
    private func scheduleSnapshotRepublish(for accountUUID: AccountUUID) {
        guard snapshotSubjects.withLock({ $0[accountUUID] != nil }) else { return }

        // Q2-1: builds no longer wait behind migration work — the SDK serves the read paths
        // from read-only connections — so requests are never dropped; the dirty/inFlight
        // coalescing below still collapses bursts to at most two builds.

        let shouldStart = snapshotRepublishState.withLock { state -> Bool in
            if state.inFlight.contains(accountUUID) {
                state.dirty.insert(accountUUID)
                return false
            }
            state.inFlight.insert(accountUUID)
            return true
        }
        guard shouldStart else { return }

        Task { [weak self] in
            await self?.republishSnapshotDrainingDirty(for: accountUUID)
        }
    }

    private func republishSnapshotDrainingDirty(for accountUUID: AccountUUID) async {
        while true {
            let snapshot = await migrationViewSnapshot(accountUUID: accountUUID)
            publishSnapshot(snapshot, for: accountUUID)

            let buildAgain = snapshotRepublishState.withLock { state -> Bool in
                if state.dirty.remove(accountUUID) != nil {
                    return true
                }
                state.inFlight.remove(accountUUID)
                return false
            }
            guard buildAgain else { return }
        }
    }

    /// R13 Brick 2b: the ONE publish point — create-if-needed, value-dedupe, and the `SNAPSHOT`
    /// trace line that makes the pipeline auditable end-to-end in the [MIG] log: a build that
    /// changed nothing says so, and a published value prints the exact figures every surface's own
    /// "SNAPSHOT applied" line must echo. DB → loader → channel → pixels, confirmable by grep.
    private func publishSnapshot(_ snapshot: MigrationViewSnapshot, for accountUUID: AccountUUID) {
        let subject = snapshotSubjects.withLock { subjects -> CurrentValueSubject<MigrationViewSnapshot?, Never> in
            if let existing = subjects[accountUUID] {
                return existing
            }
            let fresh = CurrentValueSubject<MigrationViewSnapshot?, Never>(nil)
            subjects[accountUUID] = fresh
            return fresh
        }
        guard subject.value != snapshot else {
            MigrationTrace.event("SNAPSHOT: unchanged — build produced the already-published value (deduped)")
            return
        }
        subject.send(snapshot)
        MigrationTrace.event(
            "SNAPSHOT: published — done \(snapshot.doneTransfers)/\(snapshot.totalTransfers)"
            + " · rows \(snapshot.transfers.count)"
            + " · orch \(snapshot.orchardRemaining.decimalString())"
            + " · iw \(snapshot.ironwoodHeld.decimalString())"
            + " · banner \(snapshot.banner.map { String(describing: $0) } ?? "none")"
            + (snapshot.isSubmitting ? " · SUBMITTING" : "")
        )
    }
}

// MARK: - Pure derivations (table-testable, no SDK dependency)

/// Pure mappings from SDK-observed migration state (plus a handful of app-side flags) onto what
/// the UI shows. Every function here is a straight table lookup — no dates, no I/O, no SDK types
/// beyond the value models already `Equatable`/`Sendable` (`MigrationState`, `MigrationProgress`,
/// `MigrationAttentionReason`, `MigrationTransferRow`) — so `MigrationManagerTests` can exercise
/// every row directly.
enum MigrationDerivations {
    /// MOB-1630: the smallest Orchard balance a fresh migration is offered for — ZIP 318's
    /// `MAX_RESIDUAL_VALUE` (0.01 ZEC/TAZ), the minimum migratable denomination. Below it the
    /// engine can never form a single migratable note, so `proposeMigrationTransfers` answers an
    /// EMPTY schedule (its "nothing to migrate") and an offer could only lead to a dead end: a
    /// permanent "Migration Required" banner whose tap ends on the propose-failure sheet.
    ///
    /// The floor guards the OFFER, deliberately not the run: every other banner arm describes a
    /// run that already exists, and the post-completion re-offer is gated on the engine's own
    /// answer (`isMigrationRemainderPending`) rather than on this balance read.
    static let minimumOfferableOrchardBalance = Zatoshi(1_000_000)

    /// MOB-1496 (W5): deterministic account set for the migration BG session tree and re-arm
    /// scheduler — selected account first (when present), then the rest of the wallet's accounts in
    /// their stored order, deduplicated. Shared by `Root.migrationBackgroundSessionEffect` and
    /// `MigrationBGSchedulerImpl.arm(margin:)` so both fan out over the identical account list
    /// `MigrationManagerImpl.activeNetworkSnapshots()` already uses as its own "every account with a
    /// currently-active migration run" source.
    static func candidateAccountUUIDs(selectedAccountUUID: AccountUUID?, walletAccounts: [WalletAccount]) -> [AccountUUID] {
        var seenAccountUUIDs = Set<AccountUUID>()
        var accountUUIDs: [AccountUUID] = []

        if let selectedAccountUUID, seenAccountUUIDs.insert(selectedAccountUUID).inserted {
            accountUUIDs.append(selectedAccountUUID)
        }
        for account in walletAccounts where seenAccountUUIDs.insert(account.id).inserted {
            accountUUIDs.append(account.id)
        }

        return accountUUIDs
    }

    /// P4 (outlook adoption, #2936): the engine outlook's arming candidate — the pure half.
    ///
    /// Height→date through the same measured clock every other candidate uses. 2026-08-07: the
    /// KIND used to be consulted for one thing — a `.broadcast` outlook took the post-sync privacy
    /// buffer's clamp so a poke could not invite a send the gate would refuse. With that buffer
    /// deleted there is no gate to refuse it, so every kind arms at its own window. The caller
    /// min-folds the result: an outlook can only make the poke EARLIER, never later.
    static func outlookCandidateDate(
        outlook: MigrationNextWork?,
        clock: MigrationChainClock,
        now: Date
    ) -> Date? {
        guard let outlook else { return nil }
        return clock.notificationDate(atHeight: outlook.height, now: now)
    }

    /// See MOB-1466 spec, "bannerVariant derivation" table. `isIronwoodActivated` (MOB-1483) is
    /// checked first and gates the whole derivation — pre-activation there is no banner.
    ///
    /// THE BANNER MAP (Lukas, 2026-08-06): `.transferWaiting` and its whole `hasOverdue` arm are
    /// REMOVED — overdue is iOS reality awaiting the next open, and the open auto-serves, so "tap
    /// to reschedule or send now" had no trigger left (frame 5139:17202 retired with it, along
    /// with the `isTorHoldActive`/`isProvingStalled` inputs that existed only for that arm). The
    /// nothing-actionable fall-through is the AT-OPEN idle (`.idleCounts`, idle2); the notify idle
    /// (`.idle`, idle1) is termination-only and STORE-entered — this derivation never returns it.
    ///
    /// R8-T3 (#23): dropped the `hasInvalid: Bool` parameter this function used to take — the
    /// `.invalidTransfer` case below is, and always was, decided purely by pattern-matching
    /// `state`'s own `.requiresAttention(.invalidTransfer)` case; the separate `hasInvalid` boolean
    /// input was never referenced in this body. Its only caller (`MigrationManagerImpl.bannerVariant`)
    /// no longer computes it either, removing a wasted `hasInvalidMigrationTransfers` SDK read per
    /// call. `reentryRoute` below keeps its OWN `hasInvalid` parameter — that one genuinely is
    /// consulted (row 1, `.recovery`).
    ///
    static func bannerVariant(
        isIronwoodActivated: Bool,
        state: MigrationState,
        orchardBalance: Zatoshi,
        isCompleteAcknowledged: Bool,
        isMigrationRemainderPending: Bool,
        transferRows: [MigrationTransferRow],
        preparationRows: [MigrationTransferRow] = [],
        isBroadcastInFlight: Bool = false,
        // THE BANNER MAP (Lukas, 2026-08-06): the in-flight broadcast's KIND — a note-PREPARATION
        // wears keep-open (`.preparing`), never "Transfer N is sending". See the `.inProgress`
        // arm's sending fork.
        isPreparationBroadcastInFlight: Bool = false,
        // GROUND_RULES D6: the id the current broadcast session is ACTUALLY submitting, from the
        // manager's own record — the `.transferSending` number renders this, never a row guess.
        activeBroadcastTxId: UInt32? = nil,
        round: Int = 1,
        totalRounds: Int? = nil
    ) -> MigrationBannerVariant? {
        guard isIronwoodActivated else { return nil }

        // MOB-1466 (smart-banner pass): "is the app doing work right now" is asked of the ROWS, and
        // of both lists — a note-split preparation is work exactly as much as a crossing transfer
        // is, and the split phase is where a large wallet spends its first minutes. Counts below
        // still come from `transferRows` alone; preparations are never numbered transfers.
        let workingRows = transferRows + preparationRows
        // `isInFlight`, NOT the raw `isPreparing` — the same narrowing the row caption and spinner
        // took on 08-02, applied here so all three agree by construction.
        //
        // Field-caught the same day, one session later. `isPreparing` means "the engine COULD prove
        // this one", which is true of rows whose send window is still ten minutes out. A whole run's
        // banner flipped to "preparing" because of them:
        //
        //     [MIG s2 +0.31s] BANNER: (first) → preparing
        //                     why: provable now — the prove sweep will run this session
        //     [MIG s2 …]      ROWS: … T7:preparing T8:preparing T9:preparing T10:preparing T11:~11m
        //     [MIG s2 +47.89s] ══ BACKGROUND — prove sweeps 0 · syncs completed 0
        //
        // The sweep did not run and structurally could not: `start()` had been refused by the
        // privacy gate, so there was no sync, so no sync-complete edge, so no `advance(.afterSync)`.
        // Forty-eight seconds of a banner promising imminent work, over a session that did nothing.
        //
        // `isInFlight` keeps only the rows whose own window is open or past and which cannot send
        // because their proof is outstanding — the rows a user is genuinely waiting on. A run with
        // none of those is not "preparing"; it is in progress, waiting for a window, and says so.
        let isPreparingRun = workingRows.contains { $0.isInFlight }

        // "The app is doing this RIGHT NOW, so stay" is `isBroadcastInFlight` — the in-session flag
        // `runBroadcastSession` holds for the seconds it is actually submitting — and NOT the
        // durable `.broadcast` row state.
        //
        // Field-caught 2026-08-01, one build after this pass gained a broadcast check that read the
        // ROW instead. `.broadcast(txid:)` means SUBMITTED and awaiting mining, which is minutes:
        // the submission had already returned success, the SDK's post-broadcast privacy buffer then
        // holds sync for 180 s (600 s on mainnet) so the wallet cannot even observe the mining, and
        // for that entire window the banner sat on "Keep Zodl open on active phone screen" with a
        // spinner while the app was deliberately doing nothing. The tester watched it for three
        // minutes and concluded the run had hung.
        //
        // That is the precise inversion of what these variants exist for. A keep-open ask is a
        // claim that leaving costs the user something; once the transaction is on the wire, leaving
        // costs nothing — mining is the chain's job, not the session's. The rule this restores:
        // ONLY work that dies when the app closes may ask the user to stay.
        //
        // A `.broadcast` row is still the right source for the timeline's "Sending now" caption and
        // for the banner's transfer NUMBER. It is only the keep-open ASK it must not raise.

        switch state {
        case MigrationState.notStarted:
            // MOB-1630: "below 0.01 → no offer", not "any balance → offer" — see
            // `minimumOfferableOrchardBalance`'s doc for why zero was the wrong floor.
            return orchardBalance >= minimumOfferableOrchardBalance ? MigrationBannerVariant.required : nil

        case MigrationState.splitPendingConfirmation:
            // MOB-1513 (B4): a committed run whose preps haven't all mined reads as PROGRESS — the
            // run IS running (the old `.splitting` variant shared the literal "Migration Required"
            // title, exactly QA's post-confirm confusion). Counts derive from the same row list B10
            // renders (sent count / total — normally "0 of N" right after confirm; a `.recreated`
            // re-commit keeps its preserved prior-sent rows cumulative). The engine's own
            // `progress` isn't carried by this state, and the synthesized-row fallback already
            // covers the committed-but-app-record-failed edge with progress-derived rows.
            // WORK IN FLIGHT — proving OR broadcasting, transfer OR preparation — outranks the
            // progress readout, because a "we'll notify you" line during work that only runs on
            // screen is the one message that can cost the user the work.
            //
            // Field-caught 2026-08-01, and this arm's own half-fix was the cause: the smart-banner
            // pass added the preparing check here and left the BROADCAST check in `.inProgress`
            // only. A note-split is proved at commit and broadcast later, in a scheduled window,
            // exactly like a transfer is (ZIP 318 applies to preparations too — an
            // immediately-broadcast split would be trivially correlatable with the commit). That
            // broadcast therefore happens HERE, in `splitPendingConfirmation`, and the banner read
            // "Migration Progress · We'll notify you when to send" while the timeline one tap away
            // read "Split Balance 1 · Sending now". The same two-surfaces-one-run disagreement this
            // whole pass exists to remove, surviving in the one arm the pass did not finish.
            //
            // `.preparing` rather than `.transferSending`, deliberately: the thing going out is a
            // Split Balance, not a numbered transfer, and "Transfer 1 is sending…" over a split
            // would be a confident lie. The run-level frame (spinner + "Keep Zodl open on active
            // phone screen") is true for both and asks for the one thing either needs.
            //
            // `isBroadcastInFlight` is read here too, not just the durable row: it is set the
            // instant `runBroadcastSession` starts and pokes, so it covers the seconds before the
            // engine has written `.broadcast` — which is exactly the window the field log caught.
            // THE WHOLE SPLIT PHASE IS PREPARING. Field-caught 2026-08-01: this arm used to fall
            // through to the idle banner whenever nothing was provable in that exact instant, and
            // the engine's provable-now answer flips every few seconds during the split —
            // schedule-blocked, then provable, then proved, then waiting for a broadcast window. The
            // log shows it plainly: `BANNER: required → inProgress` at +271.13s, then
            // `inProgress [held 12.69s] → preparing` at +283.82s, on a run that was doing exactly
            // one continuous thing throughout.
            //
            // Two things were wrong with that fall-through, and both matter to a user. It CHURNED —
            // "Migration Progress · We'll notify you when to send" replaced by "Migration Progress ·
            // Keep Zodl open" and back, on a timescale nobody can read. And the idle copy was a
            // false promise: `splitPendingConfirmation` means the preparations have not all mined,
            // so there is nothing to SEND yet and no send to notify about.
            //
            // RESOLVED with the two DESIGNED states and nothing invented. The first attempt gave
            // `.preparing` an `isWorkingNow` flag and a new "Preparing your balance…" line for the
            // waiting half — copy that exists nowhere in Figma, under a spinner that stayed lit
            // while the timeline showed none. Both were reported within the hour, and both were
            // fair: undesigned copy is not ours to mint, and a banner spinner over a spinner-less
            // list is the same contradiction this pass exists to remove, relocated.
            //
            // The churn it was smoothing was also smaller than feared. The field dwell times were
            // 78 s and 12 s — neither close to a flicker. The complaint that DID hold up was
            // latency (18 s blocked reads while the prove sweep held the database), which no banner
            // copy can fix.
            //
            // So: `.preparing` (Figma 5139:35270, spinner + keep-open) while the app can genuinely
            // prove or submit, and the designed idle banner otherwise. The split phase having no
            // designed "waiting" state of its own is a real gap — one for the designers, recorded
            // in SMART_BANNER_STATES §8, not one to paper over here.
            // MOB-1466 (field, 2026-08-03): `isBroadcastInFlight` REMOVED from this arm.
            //
            // `.preparing` is Figma 5139:35270 — spinner plus "Keep Zodl open on active phone
            // screen" — and it is the PROVING costume. A split-phase broadcast was wearing it, so
            // the banner span a spinner and demanded the user stay for a 5.7 s headless submit,
            // while the timeline one tap away showed no spinner at all: the rows are `ready`, then
            // `broadcast`, and NO row is ever "preparing" during a submit. Field log s2:
            //
            //     +0.09s broadcasting migration tx 0 — headless send session
            //     +0.13s BANNER -> preparing  ·  why: submitting now
            //     +5.82s BANNER: preparing [held 5.69s] -> inProgress
            //
            // The banner was not wrong that work was happening. It was wrong about WHAT KIND, and
            // it claimed the user for it.
            //
            // RE-REVERSED 2026-08-03, and the reason the first reversal was wrong is worth keeping.
            //
            // Sending a split broadcast to the idle `.inProgress` banner made the app SAY NOTHING IS
            // HAPPENING while it had a transaction open on the wire. Field log, the session a user
            // opened from a notification:
            //
            //     +0.50s broadcasting migration tx 0 — headless send session
            //     +0.58s BANNER -> inProgress  ·  why: submitting now   <- "We'll notify you when to send"
            //     +7.67s broadcast result: success(txId: dd8792ff…)
            //
            // Their tap put the note-split on the network — the transaction the entire schedule
            // depends on — and the app told them there was nothing to do. "Why did I need to open
            // Zodl? This open feels wasted." It was the single most consequential 7 seconds of the
            // run.
            //
            // What was ACTUALLY wrong the first time was not the spinner; it was that the spinner had
            // no counterpart. The complaint was "a spinner on a banner didn't also have any
            // counterpart on migration screen" — two surfaces disagreeing, the recurring bug of this
            // whole pass. I fixed it by removing the true half instead of adding the missing half.
            //
            // The missing half now exists: `MigrationTransferRow.isSubmitting` (carried on
            // `MigrationViewSnapshot`) spins the split row and captions it "Sending now" for exactly
            // the same window. Banner and screen turn on and off together, from one fact.
            //
            // `.preparing`'s user-visible copy is "Migration Progress" / "Keep Zodl open on active
            // phone screen" — nothing in it says "proving", and BOTH claims are true during a submit:
            // work is running, and backgrounding the app kills the send session. The variant's NAME
            // is the only thing that reads wrong, and users do not read variant names.
            //
            // Still NOT `.transferSending`: that one says "Transfer N is sending", and a preparation
            // is not a transfer. A dedicated split-submit state remains a real design gap
            // (SMART_BANNER_STATES §8) — this is the honest state available today, not the final one.
            //
            // `isPreparingRun` is unchanged: proving needs the app open for tens of seconds, and the
            // rows corroborate it.
            //
            // FIND-6 (2026-08-05): `.preparing` carries the run's counts — see the variant's own
            // doc for the monotone-information rule this serves (numbers, once shown, are never
            // replaced by a numberless spinner).
            if isPreparingRun || isBroadcastInFlight {
                return MigrationBannerVariant.preparing(
                    done: transferRows.filter { $0.status == MigrationTransferRow.Status.sent }.count,
                    total: transferRows.count
                )
            }
            let doneRows = transferRows.filter { $0.status == MigrationTransferRow.Status.sent }.count
            let splitDisplayRound = round >= 2 || (totalRounds ?? 1) > 1 ? round : nil
            return MigrationBannerVariant.inProgress(
                done: doneRows,
                total: transferRows.count,
                round: splitDisplayRound,
                totalRounds: splitDisplayRound != nil ? totalRounds : nil
            )

        case let MigrationState.inProgress(progress):
            // MOB-1513 (B1): an immediate (send-max) sweep in flight shows NO banner during the
            // unmined window — the balance is already spent, so there is nothing to prompt and
            // nothing to acknowledge. The engine reports `isImmediate` false, so engine runs (and
            // the `splitPendingConfirmation` remap above, itself an engine-run state) are
            // unaffected.
            if progress.isImmediate {
                return nil
            }
            // A broadcast is in flight. Checked ahead of `hasOverdue` because both are true at once
            // during a broadcast — a due transfer is exactly what is being sent — and "Transfer N is
            // waiting" while it is actually going out is the wrong half of that truth. The sending
            // banner's copy asks the user to keep the app open, which is the one thing that keeps
            // the session (and so the delivery) alive; a waiting banner asks for nothing.
            //
            // MOB-1466 (smart-banner pass): the ROW is the source now, not `isBroadcastInFlight`.
            // `.broadcast(txid:)` is durable engine state, so this arm is reachable from BOTH
            // delivery lanes (the headless one and the user's own Send now, which never touched the
            // in-memory flag and so could never raise this banner at all) and survives an app kill
            // mid-broadcast. `isBroadcastInFlight` stays only as a same-session ACCELERATOR for the
            // seconds between "we started submitting" and the engine writing `.broadcast`.
            if isBroadcastInFlight {
                // THE BANNER MAP (Lukas, 2026-08-06): the sending costume belongs to TRANSFERS
                // alone. A note-PREPARATION going out in this state (a belt-exempt tick delivery)
                // wears the keep-open costume instead, exactly as it does in the split arm —
                // splits have no banner copy of their own, and "Transfer N is sending" over a
                // split would name a transfer that is not moving.
                if isPreparationBroadcastInFlight {
                    return MigrationBannerVariant.preparing(
                        done: transferRows.filter { $0.status == MigrationTransferRow.Status.sent }.count,
                        total: transferRows.count
                    )
                }
                // GROUND_RULES D6. The number is the id the session is ACTUALLY submitting — the
                // manager records it the moment the submit starts. The previous source, `first {
                // $0.isBroadcasting }`, named the WRONG transfer whenever an earlier one was still
                // broadcast-but-unmined while a new one went out (field: "T8 is sending..." during
                // T9's submit; the screen, reading the durable rows, was right both times). Two
                // transfers can be on the wire at once; only the session knows which one is its own.
                let activeRow = activeBroadcastTxId.flatMap { id in
                    transferRows.first { $0.id == String(id) }
                }
                return MigrationBannerVariant.transferSending(
                    number: activeRow.map { $0.index + 1 } ?? nextTransferNumber(transferRows: transferRows, progress: progress)
                )
            }
            // PREPARING, ahead of both waiting arms below, and this ordering is the field fix.
            // A transfer whose window has passed while its proof is still outstanding is
            // simultaneously overdue AND un-sendable: ranked the old way the banner read "Transfer N
            // waiting · Tap to reschedule or send now", and tapping Send now returned "due but
            // awaiting proof — deferring to the next sync visit". An action that cannot succeed,
            // offered in place of the one behaviour that helps.
            //
            // MOB-1466 (2026-08-02): `reentryRoute` now ranks the ENGINE'S STEP above `hasOverdue`,
            // so an overdue run the engine is not offering a broadcast for lands on Progress rather
            // than Resume. This arm has to move with it or the two surfaces disagree again.
            //
            // FIND-6 (2026-08-05): counts on the case — monotone information, see the variant doc.
            if isPreparingRun {
                return MigrationBannerVariant.preparing(
                    done: transferRows.filter { $0.status == MigrationTransferRow.Status.sent }.count,
                    total: transferRows.count
                )
            }
            // (`.transferWaiting` — the overdue arm that lived here — was REMOVED by THE BANNER
            // MAP, Lukas 2026-08-06: overdue auto-serves at the next open/tick, so "tap to
            // reschedule or send now" had no trigger left. An overdue-but-unserved instant now
            // reads as the at-open idle below; the trace's reason line still says "window
            // passed". The `.transferReady` manual arm that followed it was REMOVED 2026-08-07
            // with the whole manual-tap send surface — its variant is deleted, not orphaned.)
            // IDLE 2 — THE BANNER MAP (Lukas, 2026-08-06): the nothing-actionable arm is the
            // AT-OPEN idle, the engine's `.waiting` rendered as a status readout — counts + ring,
            // Figma 5139:34962. The notify line (`.idle`, 35439) is TERMINATION-only and therefore
            // STORE-entered: `SmartBannerStore` presents it when a pending state resolves to this
            // answer mid-session; the derivation itself never returns `.idle`. R11's
            // rows-not-progress counting rules the numbers, same as ever. The states that land
            // here (true `.waiting`, the confirming-unmined window, a gate-refused/dep-vetoed/
            // stalled prove, an overdue instant awaiting its auto-serve) all honestly read
            // "quiet run, this far in".
            return MigrationBannerVariant.idleCounts(
                done: transferRows.filter { $0.status == MigrationTransferRow.Status.sent }.count,
                total: transferRows.count
            )

        case let MigrationState.requiresAttention(reason):
            switch reason {
            case MigrationAttentionReason.invalidTransfer:
                return MigrationBannerVariant.updatePlan

            case MigrationAttentionReason.transferExpired:
                let (first, last) = expiredBounds(transferRows: transferRows)
                return MigrationBannerVariant.transfersExpired(first: first, last: last)
            }

        case MigrationState.complete:
            // R11: the engine reaches its own `.complete` the moment the last transfer MINES per
            // its tables — one privacy-window before the wallet has synced it. Declaring "Migration
            // complete" over a timeline still showing "Confirming…" is the contradiction R4 forbids,
            // so the banner keeps the counts story until every chain-side row is wallet-confirmed.
            // Rows empty (schedule already cleared, or reads degenerate) falls through to complete —
            // engine truth when there is nothing left to render against.
            let hasUnconfirmed = (transferRows + preparationRows).contains {
                $0.status == MigrationTransferRow.Status.confirming
            }
            if hasUnconfirmed {
                let doneRows = transferRows.filter { $0.status == MigrationTransferRow.Status.sent }.count
                return MigrationBannerVariant.inProgress(
                    done: doneRows,
                    total: transferRows.count,
                    round: round >= 2 || (totalRounds ?? 1) > 1 ? round : nil,
                    totalRounds: round >= 2 || (totalRounds ?? 1) > 1 ? totalRounds : nil
                )
            }
            guard isCompleteAcknowledged else { return MigrationBannerVariant.complete }
            // MOB-1496: `.complete` is per-RUN now — the engine may still have more to migrate (a
            // per-run cap, or funds arriving mid-run). `isMigrationRemainderPending` reflects the
            // ONE fresh `proposeMigrationTransfers` this completion transition ever gets (see
            // `MigrationManagerImpl.evaluateMigrationRemainder`'s doc) — a non-empty plan re-offers
            // the banner as `.required`, exactly like a fresh pre-run balance would, with no
            // `orchardBalance` predicate needed (the engine already said there's something there).
            // MOB-1511 (W2): round-aware re-offer — the counter already incremented at this very
            // completion transition, so `round` here IS the next run's number.
            return isMigrationRemainderPending ? MigrationBannerVariant.nextRoundRequired(round: round, totalRounds: totalRounds) : nil
        }
    }

    /// See MOB-1466 spec, "reentryRoute" — §4.3 table, checked in this exact order.
    /// `isIronwoodActivated` (MOB-1483) is checked first, ahead of row 1 — pre-activation every
    /// input falls through to `.entry`.
    ///
    /// MOB-1466 (2026-08-02): `advanceStep` is now an input, and it OUTRANKS the app's own clock.
    ///
    /// THE DEAD-CTA LOOP. Every actionable route here ends in a button, and a button that the engine
    /// refuses is worse than no button: the user taps Send now, the engine answers `awaitingProof`,
    /// nothing happens, they tap Reschedule, nothing happens, and the run appears to be broken when
    /// it is merely waiting. That is exactly what an overnight testnet run produced — twelve
    /// transfers past their scheduled heights (so `hasOverdue` was true) whose engine step was
    /// `prove`, routed to a Resume screen offering a send that could not be served.
    ///
    /// The rule this encodes: THE ROUTE MAY ONLY OFFER AN ACTION THE ENGINE IS ASKING FOR. A clock
    /// reading is evidence about time, not about what the run needs — only `migrationAdvanceStep`
    /// knows that, and now it is the one that decides.
    static func reentryRoute(
        isIronwoodActivated: Bool,
        state: MigrationState,
        advanceStep: MigrationAdvanceStep?,
        hasInvalid: Bool,
        hasOverdue: Bool,
        isCompleteAcknowledged: Bool,
        progress: MigrationProgress?
    ) -> MigrationReentryRoute {
        reentryRoute(
            isIronwoodActivated: isIronwoodActivated,
            state: state,
            answer: advanceStep.map(MigrationEngineAnswer.init(step:)),
            hasInvalid: hasInvalid,
            hasOverdue: hasOverdue,
            isCompleteAcknowledged: isCompleteAcknowledged,
            progress: progress
        )
    }

    /// The route table itself, over the app's answer vocabulary — so the `.replan` and
    /// `.reevaluate` arms are reachable (and pinned) before the SDK splits them out of
    /// `.requiresAttention`. See `MigrationEngineAnswer`.
    static func reentryRoute(
        isIronwoodActivated: Bool,
        state: MigrationState,
        answer: MigrationEngineAnswer?,
        hasInvalid: Bool,
        hasOverdue: Bool,
        isCompleteAcknowledged: Bool,
        progress: MigrationProgress?
    ) -> MigrationReentryRoute {
        guard isIronwoodActivated else { return MigrationReentryRoute.entry }

        if hasInvalid {
            let isExpired = isTransferExpired(state)
            return MigrationReentryRoute.recovery(isExpired: isExpired)
        }

        // The engine is ASKING for something only the user can give. Route straight to the screen
        // whose button discharges that exact step — `.rebuild` to the expired-transfer recovery
        // (its Continue calls `refreshStaleMigrationTransfers`), `.requiresAttention` to the
        // re-plan recovery (its Continue calls `restartCurrentMigrationStep`).
        //
        // Ranked here, above every state arm, because these two steps have no other discharge in
        // the app: before this existed, a run whose next step was either of them showed whatever
        // the state arms happened to derive — usually "in progress" — while the engine waited
        // forever for a screen nothing routed to. Automatic discharge (`MigrationStepDriver`)
        // handles the cases it can; this is the route for the cases it cannot.
        switch answer {
        case MigrationEngineAnswer.rebuild?:
            return MigrationReentryRoute.recovery(isExpired: true)
        case MigrationEngineAnswer.replan?:
            // THE RE-PLAN LANE, named by the engine. Never `isExpired` — a replan is about the
            // plan's coverage, not about any transfer's expiry, so it lands on the notes-spent
            // screen (Figma C5) whose Continue discharges the run and re-plans. No
            // `isTransferExpired` consultation: a replan needs no disambiguation.
            return MigrationReentryRoute.recovery(isExpired: false)
        case MigrationEngineAnswer.reevaluate?:
            // DELIBERATELY NOT A ROUTE. The engine wants a sync, not a user — routing here would
            // hand the user a "re-plan this run" button for a live run whose transfers are all
            // intact. Falls through to the state arms, which read it as the in-progress run it is.
            break
        default:
            break
        }

        // BEFORE `hasOverdue`, deliberately. During the split phase a transfer can pass its
        // scheduled height while its PREPARATION has not yet mined: the transfer is then "overdue"
        // by the clock and un-sendable by the engine, which refuses it on unmet dependencies.
        //
        // Ranked the other way round — as it was until the 07-31 test session — that routed the user
        // to the Resume screen offering an ENABLED "Send now" for a transfer nothing could send,
        // while the banner, which only consults `hasOverdue` inside `.inProgress`, read "Migration in
        // Progress · 0 of 12" from the very same inputs. Two surfaces, one state, opposite stories.
        //
        // Safe because the route decides only WHICH SCREEN a banner tap opens. Delivery is driven by
        // `runBroadcastSession` on every app open regardless of route, so a transfer that does become
        // broadcastable mid-split still goes out headlessly — this costs no delivery and removes an
        // action that could not succeed.
        //
        // Far likelier on testnet than mainnet: the 1/12 anchor-grid compression can put a transfer's
        // window within a couple of blocks of its preparation's broadcast, where mainnet's 144-block
        // grid leaves preparations hours to mine first.
        if case MigrationState.splitPendingConfirmation = state {
            // MOB-1513 (B4): the split phase re-enters on B10 Migration Progress — the "Splitting
            // Funds" screen (and its dedicated route) no longer exist.
            return MigrationReentryRoute.statusProgress
        }

        // Both of the routes below end in a SEND button, so both now require the engine to actually
        // be offering a broadcast. `hasOverdue` is an app-side height comparison: it can tell you
        // a window has opened, but not whether the transfer inside it is proved, whether its
        // dependencies mined, or whether the engine considers it deliverable at all. Only
        // `.broadcast` means "deliverable right now" — everything else that looks overdue is a run
        // doing its job, and falls through to the honest progress screen below.
        // (The `reviewManual` arm that followed this one was REMOVED 2026-08-07 with the whole
        // manual-tap send surface.)
        let isBroadcastOffered: Bool
        if case MigrationEngineAnswer.broadcast? = answer { isBroadcastOffered = true } else { isBroadcastOffered = false }

        if hasOverdue && isBroadcastOffered {
            return MigrationReentryRoute.statusResume
        }

        if case let MigrationState.inProgress(inFlightProgress) = state {
            // MOB-1513 (B1): an immediate (send-max) sweep in flight has no per-transfer status
            // screen to resume into — route to `.entry` so re-entry stays quiet during the unmined
            // window. Engine runs (`isImmediate` false) still resume on the status screen.
            if inFlightProgress.isImmediate {
                return MigrationReentryRoute.entry
            }
            return MigrationReentryRoute.statusProgress
        }

        if case MigrationState.complete = state {
            return isCompleteAcknowledged ? MigrationReentryRoute.entry : MigrationReentryRoute.complete
        }

        return MigrationReentryRoute.entry
    }

    /// The 1-based number of the transfer the banner is TALKING ABOUT — the first row that has not
    /// sent, by its own position in the row list, falling back to `completedTransfers + 1` when
    /// there are no rows to read.
    ///
    /// MOB-1466 (smart-banner pass). This is the "Transfer 1 finished but the banner still says
    /// Transfer 1" bug, and it was not a refresh problem. `completedTransfers` counts MINED
    /// transfers, and a transfer mines minutes after it sends — so for that whole window the old
    /// `completedTransfers + 1` named the transfer that had already gone out, while the timeline
    /// (which numbers rows by position) had correctly moved on to the next one. Two surfaces, one
    /// run, off by one, for as long as a confirmation takes.
    ///
    /// Reading position from the same rows the timeline renders makes them agree by construction:
    /// the row list is contiguous across prior-run sent rows and the current schedule, and display
    /// numbers are `index + 1` in both places.
    /// The transfer the banner NAMES — "Transfer N is waiting", "Transfer N is ready".
    ///
    /// Skips rows already on the wire (`isBroadcasting`), and that omission was the bug (field,
    /// 2026-08-03). This predicate knew two states, sent and not-sent, while a row has three: sent,
    /// SUBMITTED-AWAITING-MINING, and actually waiting. A submitted row is `.active` — not `.sent` —
    /// so it counted as "the next transfer" and the banner asked the user to send a transaction that
    /// was already on the network. From one log line:
    ///
    ///     BANNER → transferWaiting(number: 4)
    ///     ROWS: T1:done T2:done T3:done T4:broadcast T5:ready …
    ///
    /// The timeline, reading the SAME row, captioned T4 "Sent recently" (`isBroadcasting`). Two
    /// surfaces, one row, opposite claims — and unlike every earlier instance of this, not a timing
    /// gap: both were derived from one read, in one pass, and still disagreed, because only one of
    /// them knew the third state existed.
    ///
    /// "Waiting" means waiting ON THE USER. A submitted transfer waits on the chain, needs nothing,
    /// and must not be offered a "Send now".
    private static func nextTransferNumber(transferRows: [MigrationTransferRow], progress: MigrationProgress) -> Int {
        // R11: `.confirming` skipped alongside `.sent` — a confirming row is on the chain's side
        // and nothing the user does applies to it, so it can never be the "Transfer N" a waiting
        // or ready banner names.
        let firstActionable = transferRows.first {
            $0.status != MigrationTransferRow.Status.sent
                && $0.status != MigrationTransferRow.Status.confirming
                && !$0.isBroadcasting
        }
        guard let firstActionable else {
            // Every remaining row is sent or in flight: nothing is waiting on the user, so the
            // progress count is the only honest number left to name.
            return progress.completedTransfers + 1
        }
        return firstActionable.index + 1
    }

    /// Bounds for `.transfersExpired(first:last:)`: 1-based first/last position among rows whose
    /// status is `.expired`; fallback `(1, total)` when none are marked expired (including an
    /// empty row list, which falls back to `(1, 0)`).
    private static func expiredBounds(transferRows: [MigrationTransferRow]) -> (first: Int, last: Int) {
        let expiredIndexes = transferRows
            .filter { $0.status == MigrationTransferRow.Status.expired }
            .map { $0.index + 1 }

        guard let first = expiredIndexes.min(), let last = expiredIndexes.max() else {
            return (1, transferRows.count)
        }

        return (first, last)
    }

    private static func isTransferExpired(_ state: MigrationState) -> Bool {
        guard case let MigrationState.requiresAttention(reason) = state else { return false }
        return reason == MigrationAttentionReason.transferExpired
    }

    // MARK: - MOB-1496 (W2): persisted-schedule row/summary derivation

    /// One row per `committedSchedule.schedule.transfers` element, PLUS one leading row per
    /// `sentRecords` entry whose `transferId` is NOT in the current schedule (a prior-run sent
    /// transfer from before a restart) — so a re-created plan's full logical run renders, prior
    /// sent rows first, then the current schedule in order. `index` is 0-based and contiguous
    /// across the WHOLE combined list (display code adds 1, matching every other row-index
    /// consumer in this file).
    ///
    /// Per-row status precedence:
    /// 1. has a sent record (leading rows always do; a schedule row does when its own `id` matches
    ///    one) -> `.sent`.
    /// 2. `.requiresAttention(.invalidTransfer(transferId:))` matching this row's id -> `.invalid`
    ///    (checked for every non-sent row, not just the first — an invalid note can be any pending
    ///    transfer, not necessarily the earliest).
    /// 3. the first non-sent row, when state is `.requiresAttention(.transferExpired)` -> `.expired`
    ///    (the reason carries no transfer id of its own, so the earliest pending row stands in for
    ///    "the" expired one).
    /// 4. the first non-sent row, when `hasOverdueMigrationTransfers` -> `.overdue`.
    /// 5. the first non-sent row otherwise -> `.active`.
    /// 6. every other non-sent row -> `.pending`.
    ///
    /// `hoursFromNow`/`minutesFromNow` (MOB-1513 A3): sent rows carry "hours ago" (floor) +
    /// `sentMinutesAgo` (sub-hour precision) — unchanged. Non-sent rows now carry the REAL forward
    /// ETA: a block delta between the row's own `nextExecutableAfterHeight` (threaded through
    /// `RowSeed` from the matching schedule transfer — leading rows are always `.sent` and never
    /// reach this branch, so their height is an unused placeholder) and `currentTip`, via
    /// `MigrationETA.minutesFromNow(scheduledHeight:currentTip:)` — the same helper, fed the same
    /// tip source (`sdkSynchronizer.latestState().latestBlockHeight`), the Transfer Plan screen's
    /// `MigrationTransferPlanStore.apply` already uses. `minutesFromNow` carries the minute-precise
    /// value (so a sub-hour transfer reads "in ~N mins"); `hoursFromNow` keeps a coarse whole-hour
    /// copy (`minutes / 60`) for callers that only read that field. A height at/behind `currentTip`
    /// (or an unknown `currentTip <= 0`) floors to `0` — "Ready now" — per `minutesFromNow`'s own
    /// fail-safe. This replaces the old W1 index-cadence placeholder (`nonSentPosition × 6h`), which
    /// never read the schedule's real heights at all. MOB-1513 (T-A): a matched live status's own
    /// `scheduledHeight` takes precedence over this persisted height — see `statuses`' doc below.
    ///
    /// R7's refresh lane (`refreshStaleMigrationTransfers`) persists its RETURNED schedule via
    /// `recordCommittedSchedule` before this derivation ever runs again (see
    /// `MigrationCoordFlowCoordinator`'s recovery-refresh lane) — since this function takes
    /// `committedSchedule` as a plain input and caches nothing, a post-refresh call always
    /// re-derives every row's ETA from the freshly-persisted heights, never a stale pre-refresh one.
    ///
    /// Amounts come from the persisted proposal (schedule rows) or the sent record itself (leading
    /// rows) — never from live progress or the live status (MOB-1513 T-A: a `MigrationTransactionStatus`
    /// carries no amount by design — see its own `id` doc — so the persisted schedule stays the sole
    /// amount source even on the live-preferred path below).
    ///
    /// MOB-1513 (T-A): `statuses` — the engine's LIVE per-transaction migration statuses, `[]` by
    /// default (every pre-T-A call site/test omits it and is byte-identical to before: the fallback
    /// path above stays fully in play whenever the caller's own SDK read threw or returned `[]`, per
    /// `MigrationManagerImpl.migrationTransfers`'s doc). When non-empty, its per-transaction state
    /// PREFERS over the app-derived precedence table above for every SCHEDULE row it can join to
    /// (never the leading prior-run rows, which have no live join target of their own): only
    /// `.transfer`-kind statuses join (a `.preparation`-kind status — a note-split transaction — is
    /// never displayed as a transfer row); the join key is `String(status.id) == transfer.id`
    /// (`MigrationTransactionStatus.id`'s own doc: "the same ordinal the schedule surfaces carry as
    /// their opaque string id"), independent of `statuses`' own order. A schedule row with no
    /// matching status (a partial/shuffled `statuses` read, or one still `.preparation`-only) simply
    /// falls through to the table above unaffected — never a crash, never a misattributed row. Per
    /// matched row:
    /// 1. `.mined` -> `.sent`, even when the app's own `sentRecord` bookkeeping hasn't caught up
    ///    (live truth wins over app-derived truth) — elapsed time still prefers a real
    ///    `sentRecord.sentAt` when one exists (never discards real data the app already has);
    ///    absent one, reads as "sent recently" (`hoursFromNow == 0`, `sentMinutesAgo == nil` — see
    ///    `MigrationTransferRow.sentMinutesAgo`'s doc).
    /// 2. `.broadcast(txid:)` -> the existing broadcasting/sent-pending styling: `.active` +
    ///    `isBroadcasting: true` (regardless of position — a row actually in flight right now is
    ///    unambiguously "the" active one; no new UI state).
    /// 3. `blockedOn == .expired` -> `.expired`, the same case row 3 of the table above already
    ///    renders, but decided per-row from live ground truth rather than gated on the aggregate
    ///    `state == .requiresAttention(.transferExpired)` + first-non-sent position.
    /// 4. every other state (`.awaitingSignature`/`.signed`/`.proved`, not expired) -> the table
    ///    above, position/`state`-driven, MINUS its own `.expired` case (`.active`/`.overdue`/
    ///    `.pending`/`.invalid` only — see `nonSentRowStatus`'s `hasLiveStatus` doc): a row that
    ///    reaches here already had its one shot at `.expired` in item 3 above and didn't take it,
    ///    which is live ground truth this row specifically is NOT expired, so the table's own
    ///    aggregate-`state`-driven `.expired` reading (true for the WHOLE run, not this row) must
    ///    not override that. The row's ETA feeds from the matched status's own `scheduledHeight`
    ///    rather than the persisted schedule's `nextExecutableAfterHeight`.
    static func transferRows(
        committedSchedule: MigrationCommittedSchedule,
        state: MigrationState,
        hasOverdueMigrationTransfers: Bool,
        now: Date,
        clock: MigrationChainClock,
        statuses: [MigrationTransactionStatus] = [],
        isProvingStalled: Bool = false,
        // GROUND_RULES R11: the display-form hex txids the WALLET'S OWN store has observed mined
        // (`walletMinedTxIds`) — the set that decides `.sent` vs `.confirming`. `nil` means no
        // wallet read has ever succeeded: engine truth then stands for engine-MINED rows, while a
        // merely-broadcast row is `.confirming` even then — it was never green-worthy (see
        // `chainSideDisposition` below). NOTE nil is NOT the pre-R11 behaviour: before R11 a
        // sentRecord alone (broadcast success) rendered green.
        confirmedTxIds: Set<String>? = nil
    ) -> [MigrationTransferRow] {
        struct RowSeed {
            let transferId: String
            let amount: Zatoshi
            let sentRecord: MigrationCommittedSchedule.SentRecord?
            /// The height after which the engine may broadcast this transfer — `0` (unused
            /// placeholder) for leading rows, which always carry a `sentRecord` and so never reach
            /// the forward-ETA branch below.
            let nextExecutableAfterHeight: BlockHeight
            /// MOB-1513 (T-A): this row's LIVE per-transaction status, joined by id — `nil` for
            /// leading rows (no join target) and for a schedule row `statuses` carries no current
            /// `.transfer`-kind entry for. See `transferRows`'s own doc for the full join contract.
            let liveStatus: MigrationTransactionStatus?
        }

        let scheduleTransferIds = Set(committedSchedule.schedule.transfers.map { $0.transferKey })
        let sentRecordsByTransferId = Dictionary(
            committedSchedule.sentRecords.map { ($0.transferId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // MOB-1513 (T-A): only `.transfer`-kind statuses ever join to a displayed row (preparation
        // transactions are never displayed as transfer rows); keyed by id so a shuffled `statuses`
        // array joins identically, and a defensive duplicate id keeps its first occurrence — same
        // `uniquingKeysWith` convention as `sentRecordsByTransferId` above.
        let liveStatusesByTransferId: [String: MigrationTransactionStatus] = Dictionary(
            statuses.compactMap { status -> (String, MigrationTransactionStatus)? in
                guard case MigrationTransactionStatus.Kind.transfer = status.kind else { return nil }
                return (String(status.id), status)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let leadingRows: [RowSeed] = committedSchedule.sentRecords
            .filter { !scheduleTransferIds.contains($0.transferId) }
            .map { RowSeed(transferId: $0.transferId, amount: $0.amount, sentRecord: $0, nextExecutableAfterHeight: 0, liveStatus: nil) }
        let scheduleRows: [RowSeed] = committedSchedule.schedule.transfers.map { transfer in
            RowSeed(
                transferId: transfer.transferKey,
                amount: transfer.amount,
                sentRecord: sentRecordsByTransferId[transfer.transferKey],
                nextExecutableAfterHeight: transfer.nextExecutableAfterHeight,
                liveStatus: liveStatusesByTransferId[transfer.transferKey]
            )
        }

        // MOB-1466 (M2): schedule rows display in broadcast-SLOT order, not the committed array's
        // crossing order — the engine's ZIP-318 permutation deliberately shuffles crossing↔slot
        // (denomination rank must not leak into broadcast time), so the array order renders a
        // shuffled timeline. Slot sort is chain-invisible; numeric-id tiebreak keeps same-slot
        // rows deterministic. Leading rows (pre-schedule history) stay first, as before.
        let seeds = leadingRows + scheduleRows.sorted {
            ($0.nextExecutableAfterHeight, Int($0.transferId) ?? Int.max)
                < ($1.nextExecutableAfterHeight, Int($1.transferId) ?? Int.max)
        }

        func isLiveBroadcast(_ seed: RowSeed) -> Bool {
            guard let liveStatus = seed.liveStatus, case MigrationTransactionStatus.State.broadcast = liveStatus.state else {
                return false
            }
            return true
        }
        func isEngineMined(_ seed: RowSeed) -> Bool {
            guard let liveStatus = seed.liveStatus, case MigrationTransactionStatus.State.mined = liveStatus.state else {
                return false
            }
            return true
        }
        // GROUND_RULES R11 — the three-way judgment that replaced the old boolean "sent".
        //
        // Whether a row is ON THE CHAIN'S SIDE of the turnstile (engine-mined, app-recorded
        // broadcast, or live `.broadcast`) is judged exactly where the old `isSent` was. What R11
        // changes is which chain-side rows render GREEN: only those the WALLET'S OWN store has
        // observed mined (`confirmedTxIds` — the same source Activity and the home balances read).
        // Every other chain-side row is `.confirming`. The old rule made a row green at broadcast
        // success (sentRecord presence) — two phases before "done" has pool impact, which is how
        // the field got three green checks summing 55.2 ZEC over an Ironwood balance of 0.
        //
        // Fallbacks, deliberate and narrow:
        // - `confirmedTxIds == nil` (no wallet read has EVER succeeded): ENGINE truth stands for
        //   engine-MINED rows — un-confirming the whole timeline over a read failure would repaint
        //   every green as "Confirming…", a worse lie than the one R11 removes. Merely-broadcast
        //   rows are `.confirming` even then: they were never green-worthy.
        // - engine-mined with NO matchable txid (`sentRecord` missing or its `txId` nil — the
        //   record-failed-after-broadcast edge): engine truth stands — a row we can never match
        //   would otherwise read "Confirming…" forever.
        func chainSideDisposition(_ seed: RowSeed) -> MigrationTransferRow.Status? {
            let engineMined = isEngineMined(seed)
            guard engineMined || seed.sentRecord != nil || isLiveBroadcast(seed) else { return nil }

            guard let confirmedTxIds else {
                return engineMined ? MigrationTransferRow.Status.sent : MigrationTransferRow.Status.confirming
            }
            if let txId = seed.sentRecord?.txId, confirmedTxIds.contains(txId) {
                return MigrationTransferRow.Status.sent
            }
            // The wallet's store can know a mined txid the app's own record is missing — the live
            // `.broadcast` payload carries it in raw byte order; match it in display form too.
            if let liveStatus = seed.liveStatus,
                case let MigrationTransactionStatus.State.broadcast(txid) = liveStatus.state,
                confirmedTxIds.contains(txid.toHexStringTxId()) {
                return MigrationTransferRow.Status.sent
            }
            if engineMined && seed.sentRecord?.txId == nil {
                return MigrationTransferRow.Status.sent
            }
            return MigrationTransferRow.Status.confirming
        }
        let firstNonChainSideIndex = seeds.firstIndex { chainSideDisposition($0) == nil }

        return seeds.enumerated().map { index, seed in
            if let chainSideStatus = chainSideDisposition(seed) {
                guard let sentRecord = seed.sentRecord else {
                    // MOB-1513 (T-A): live-mined/broadcast with no app-recorded `sentRecord` —
                    // chain-side, with no known recency (see this function's own doc, precedence
                    // item 1).
                    return MigrationTransferRow(
                        id: seed.transferId,
                        index: index,
                        amount: seed.amount,
                        status: chainSideStatus,
                        hoursFromNow: 0,
                        isBroadcasting: isLiveBroadcast(seed)
                    )
                }
                let elapsedMinutes = max(0, Int(now.timeIntervalSince(sentRecord.sentAt) / 60))
                return MigrationTransferRow(
                    id: seed.transferId,
                    index: index,
                    amount: seed.amount,
                    status: chainSideStatus,
                    hoursFromNow: elapsedMinutes / 60,
                    sentMinutesAgo: elapsedMinutes < 60 ? elapsedMinutes : nil,
                    isBroadcasting: isLiveBroadcast(seed)
                )
            }

            // A25 (SDK addendum §3): a row the engine marked `.invalid` names ITSELF. Checked
            // immediately below "sent", mirroring the SDK's own rule that chain inclusion outranks
            // an invalid verdict — a stale verdict must never shadow a landed transaction — and
            // above everything else, because no chain condition makes an invalid row actionable
            // again. This is what retires the old "the first non-sent row wears the badge" guess:
            // per-row identity now comes from per-row data.
            if let liveStatus = seed.liveStatus, case MigrationTransactionStatus.State.invalid = liveStatus.state {
                let minutesFromNow = MigrationETA.minutesFromNow(scheduledHeight: liveStatus.scheduledHeight, clock: clock)
                return MigrationTransferRow(
                    id: seed.transferId,
                    index: index,
                    amount: seed.amount,
                    status: MigrationTransferRow.Status.invalid,
                    hoursFromNow: (minutesFromNow ?? 0) / 60,
                    minutesFromNow: minutesFromNow,
                    isETAKnown: minutesFromNow != nil
                )
            }

            // R11: the old standalone `.broadcast` arm (status `.active` + `isBroadcasting`) lived
            // here — a live-broadcast row is chain-side now and was judged above, so the arm is
            // gone rather than left dead.

            // MOB-1513 (T-A): a live-expired row is unambiguous per-row ground truth (see this
            // function's own doc, precedence item 3).
            if let liveStatus = seed.liveStatus, liveStatus.blockedOn == MigrationTransactionStatus.Blocker.expired {
                let minutesFromNow = MigrationETA.minutesFromNow(scheduledHeight: liveStatus.scheduledHeight, clock: clock)
                return MigrationTransferRow(
                    id: seed.transferId,
                    index: index,
                    amount: seed.amount,
                    status: MigrationTransferRow.Status.expired,
                    hoursFromNow: (minutesFromNow ?? 0) / 60,
                    minutesFromNow: minutesFromNow,
                    isETAKnown: minutesFromNow != nil
                )
            }

            // FIND-1 (2026-08-05, campaign 7): whether THIS row's engine status says it is waiting
            // on other transactions of its own run (unmined preparations, an earlier transfer).
            // Feeds two honesty rules below: the schedule-clock `.overdue` badge never lands on a
            // row the clock cannot serve, and the caption says what the row is actually waiting
            // for. `nil` liveStatus stays `false` — no guess.
            let isAwaitingRunDependencies = seed.liveStatus?.blockedOn == MigrationTransactionStatus.Blocker.dependencies

            let status = nonSentRowStatus(
                transferId: seed.transferId,
                isFirstNonSent: index == firstNonChainSideIndex,
                state: state,
                hasOverdueMigrationTransfers: hasOverdueMigrationTransfers,
                hasLiveStatus: seed.liveStatus != nil,
                isAwaitingRunDependencies: isAwaitingRunDependencies
            )
            // MOB-1513 (T-A): a matched live status's own `scheduledHeight` feeds the ETA in
            // preference to the persisted schedule's `nextExecutableAfterHeight` (see this
            // function's own doc, precedence item 4).
            let scheduledHeight = seed.liveStatus?.scheduledHeight ?? seed.nextExecutableAfterHeight
            let minutesFromNow = MigrationETA.minutesFromNow(scheduledHeight: scheduledHeight, clock: clock)

            return MigrationTransferRow(
                id: seed.transferId,
                index: index,
                amount: seed.amount,
                status: status,
                hoursFromNow: (minutesFromNow ?? 0) / 60,
                minutesFromNow: minutesFromNow,
                isPreparing: isPreparing(seed.liveStatus, isProvingStalled: isProvingStalled),
                isAwaitingRunDependencies: isAwaitingRunDependencies,
                isAwaitingAnchorBoundary: seed.liveStatus?.blockedOn == MigrationTransactionStatus.Blocker.anchorBoundary,
                // D4: real elapsed for the overdue caption (Figma B8 "Overdue · 5h ago").
                overdueMinutesAgo: status == MigrationTransferRow.Status.overdue
                    ? MigrationETA.overdueMinutes(scheduledHeight: scheduledHeight, clock: clock)
                    : nil
            )
        }
    }

    /// Whether the engine says this transaction can be PROVED right now — see
    /// `MigrationTransferRow.isPreparing`'s doc for why readiness, not lifecycle state, is the
    /// signal. `nil` (no joined live status) is `false`: a row the join could not match says
    /// nothing about proving, and guessing "preparing" from position would put a "keep Zodl open"
    /// ask on a row that may be hours from needing anything.
    ///
    /// MOB-1466: `nextAction` had no reader anywhere in the app before this — the engine has been
    /// answering "prove or broadcast?" per transaction since the model landed and nothing asked.
    private static func isPreparing(_ status: MigrationTransactionStatus?, isProvingStalled: Bool = false) -> Bool {
        // A stalled sweep revokes the claim outright. The engine still says "ready to prove" — that
        // is precisely the contradiction — but the app has watched proving produce nothing twice
        // running, and a caption saying "Preparing transaction…" over work that is not progressing
        // is a lie the user pays for by sitting and waiting. See `MigrationManagerImpl
        // .isProvingStalled`.
        guard !isProvingStalled, let status else { return false }
        return status.isReady && status.nextAction == MigrationTransactionStatus.NextAction.prove
    }

    /// MOB-1513 (T-A fix wave 1): `hasLiveStatus` gates the aggregate-state `.expired` heuristic
    /// below — a row that HAS a joined live status already had its chance to be marked `.expired`
    /// from that status's own `blockedOn` (checked by the caller BEFORE this fallthrough is ever
    /// reached — see `transferRows`'s own doc, precedence item 3); reaching here with
    /// `hasLiveStatus == true` is live GROUND TRUTH that this specific row is not expired, so the
    /// aggregate `state == .requiresAttention(.transferExpired)` reading (true for the WHOLE run,
    /// not this row) must not override it. The heuristic stays live only for a row the join
    /// couldn't match at all (no live status to consult) — e.g. an expired transfer the persisted
    /// schedule/`statuses` read doesn't currently cover. `.invalid`/`.overdue`/`.active` are
    /// unaffected — only the `.expired` branch was ever backed by this position-plus-aggregate-flag
    /// proxy instead of a per-row signal.
    ///
    /// FIND-1 (2026-08-05, campaign 7): `isAwaitingRunDependencies` vetoes the `.overdue` badge.
    /// `hasOverdueMigrationTransfers` is a WALLET-WIDE aggregate, and the engine's overdue set
    /// counts preparation rows too — so a due note-split put "Overdue · 1 min ago" on Transfer 1
    /// while the very preparations that fund it were still unmined. A row the engine says is
    /// waiting on its own run's dependencies is ON PLAN, not late: the clock passing its height
    /// changes nothing the user (or the app) can act on, and the engine re-draws that height at
    /// release anyway. Such a row stays `.active` (it is still the front of the queue) and its
    /// caption comes from the dependency truth, not the clock — see `MigrationStatusView`'s
    /// caption arm.
    private static func nonSentRowStatus(
        transferId: String,
        isFirstNonSent: Bool,
        state: MigrationState,
        hasOverdueMigrationTransfers: Bool,
        hasLiveStatus: Bool,
        isAwaitingRunDependencies: Bool = false
    ) -> MigrationTransferRow.Status {
        // A25, RESOLVED (SDK addendum §3). This used to put the invalid badge on the first non-sent
        // row whenever the RUN reported an invalidation, because nothing said which transfer was
        // meant. `MigrationTransactionStatus.State.invalid(reason:)` now says, so the badge is
        // decided per-row by the callers above, from the row's own status — and the guess is gone.
        // A run-level invalidation with no per-row verdict (the "plan no longer covers the balance"
        // case) stays a run-level statement: the `.updatePlan` banner, not a badge on an arbitrary
        // row.
        guard isFirstNonSent else { return MigrationTransferRow.Status.pending }

        if !hasLiveStatus, case MigrationState.requiresAttention(MigrationAttentionReason.transferExpired) = state {
            return MigrationTransferRow.Status.expired
        }

        return hasOverdueMigrationTransfers && !isAwaitingRunDependencies
            ? MigrationTransferRow.Status.overdue
            : MigrationTransferRow.Status.active
    }

    /// `transferred`/`transfersSent` come straight from `sentRecords`; `transfersTotal` adds the
    /// current schedule's still-unsent transfers (excludes any already covered by a sent record, so
    /// a re-committed schedule doesn't double-count); `estimatedDurationHours` is the persisted
    /// schedule's own estimate. `dust`: `residual` (already flattened `threw-or-nil -> nil` by the
    /// caller) when available; while `state == .complete` and residual isn't, `progress
    /// .remainingOrchard` (whatever's left over at completion is the best available proxy); `.zero`
    /// otherwise.
    /// - Parameter orchardBalance: the account's LIVE Orchard balance, the `.complete` fallback. See
    ///   the `dust` derivation below for why `progress` cannot serve that role. Defaults to `.zero`
    ///   so the many call sites that predate this keep their exact behaviour.
    static func summary(
        committedSchedule: MigrationCommittedSchedule,
        state: MigrationState,
        residual: Zatoshi?,
        progress: MigrationProgress?,
        orchardBalance: Zatoshi = .zero
    ) -> MigrationSummary {
        let transferred = committedSchedule.sentRecords.reduce(Zatoshi.zero) { $0 + $1.amount }
        let sentTransferIds = Set(committedSchedule.sentRecords.map { $0.transferId })
        let unsentScheduleCount = committedSchedule.schedule.transfers.filter { !sentTransferIds.contains($0.transferKey) }.count

        let dust: Zatoshi
        if let residual {
            dust = residual
        } else if state == MigrationState.complete {
            // MOB-1458 (field-caught 2026-08-02): this fallback used to read
            // `progress?.remainingOrchard`, and it could NEVER fire. The SDK's own contract for
            // `migrationProgress` is explicit — "a terminal — complete or cancelled — run reports
            // `nil`" — and this branch is reached only when `state == .complete`. So `progress` was
            // nil by construction, the expression collapsed to `.zero`, and `dust` was always zero
            // on the one screen that exists to resolve it.
            //
            // The cost was the whole done-flow: `MigrationComplete.State.hasDust` is `dust > 0`, so
            // with zero dust the residual card, "Migrate anyway" and "Lock balance" all vanished and
            // the screen showed a bare summary. That is exactly what the first tester reported —
            // "only migration done, summary" — and it read as a missing feature rather than a bug,
            // because the feature was fully built behind a predicate that could not become true.
            //
            // The live Orchard balance is the right fallback and was available all along: the banner
            // has been printing it correctly at `.complete` throughout ("state complete, orchard
            // 0,005" in the 08-02 completion log) via `orchardBalanceToMigrate`.
            dust = orchardBalance
        } else {
            dust = Zatoshi.zero
        }

        return MigrationSummary(
            transferred: transferred,
            dust: dust,
            transfersSent: committedSchedule.sentRecords.count,
            transfersTotal: committedSchedule.sentRecords.count + unsentScheduleCount,
            estimatedDurationHours: committedSchedule.schedule.estimatedDurationHours
        )
    }

    /// MOB-1513 (W1 fallback wave 2): rows derived PURELY from the engine's LIVE per-transaction
    /// migration statuses (`sdkSynchronizer.migrationTransactionStatuses`) — the preferred fallback
    /// a caller takes when no committed schedule is persisted yet (a restore, or a fresh install
    /// mid-migration; see `MigrationManagerImpl.migrationTransfers`'s doc). Unlike `transferRows`
    /// above, there is no persisted schedule or `sentRecords` to join against, so every row's
    /// `amount` is `nil` — a `MigrationTransactionStatus` carries no amount by design (see its own
    /// `id` doc), and this is the only data source available on this path.
    ///
    /// Filters to `.transfer`-kind statuses only (a `.preparation`-kind status is a note-split
    /// transaction, never displayed as a transfer row) — returns `nil` when none remain, the
    /// "nothing to show yet" signal a caller falls further back from (to
    /// `MigrationManagerImpl.synthesizedTransferRows`, the pure progress-count approximation).
    /// Never an empty array, which would read as "the run has zero transfers" — a different and
    /// wrong claim. Sorted by scheduled SLOT (`scheduledHeight`, `crossing` tiebreak — MOB-1466 M2:
    /// `crossing` ranks denominations and is deliberately shuffled against time by the engine's
    /// ZIP-318 permutation, so slot order is the only order a timeline can honestly render);
    /// a row's `index`/display position follows that sort,
    /// and `id` is `String(status.id)` — the SAME opaque ordinal a schedule row would carry for the
    /// same transaction (`MigrationTransactionStatus.id`'s own doc), so a later read that DOES gain
    /// a persisted schedule joins to the identical id.
    ///
    /// Per-row status mirrors `transferRows`'s live-status precedence above (items 1-2 verbatim;
    /// this fallback has no aggregate `state`/`hasOverdueMigrationTransfers` to consult for the
    /// remaining cases, so items 3-4 below substitute an equivalent PER-ROW signal):
    /// 1. `.mined` -> `.sent`, `hoursFromNow: 0`, `sentMinutesAgo: nil` (no `sentRecord` on this
    ///    path at all — always reads "sent recently", same convention `transferRows` uses for a
    ///    live-mined status with no matching `sentRecord`).
    /// 2. `.broadcast` -> `.active` + `isBroadcasting: true` (the existing broadcasting/sent-
    ///    pending styling, regardless of position — same convention as `transferRows`'s own item
    ///    2).
    /// 3. `blockedOn == .expired` -> `.expired`, regardless of position.
    /// 4. The FIRST row in slot order among everything else (mirrors `transferRows`'s own
    ///    "only the earliest non-terminal row is ever the acted-on one" convention — ZIP-0318
    ///    MUST: at most one broadcast at a time): `.overdue` when its own `scheduledHeight` is
    ///    at/behind `currentTip` (the same "already due" reading `MigrationETA.minutesFromNow`
    ///    floors to zero for), else `.active`. Every OTHER row -> `.pending`.
    ///
    /// ETAs (`hoursFromNow`/`minutesFromNow`) for rows in cases 2-4 come from `MigrationETA
    /// .minutesFromNow(scheduledHeight:currentTip:)` fed the row's own live `scheduledHeight` —
    /// never negative, never a fake future value for a past-due row (floors to `0`, "Ready now").
    ///
    /// Deliberately NOT restructured around `transferRows`' internals above — that function's
    /// committed-schedule behavior is out of scope for this fallback (reuse of its PUBLIC
    /// conventions yes, restructuring its internals no); this stays a small, self-contained
    /// function that mirrors those conventions by construction instead. The one shared private
    /// helper is `isPreparing(_:)`, a two-line pure predicate over a single status — sharing it is
    /// what keeps the two paths from drifting on the same question, which is the opposite of the
    /// coupling this note guards against.
    static func statusOnlyTransferRows(
        statuses: [MigrationTransactionStatus],
        clock: MigrationChainClock,
        isProvingStalled: Bool = false,
        // GROUND_RULES R11 — see `transferRows`. In this lane an engine-`.mined` row carries no
        // txid to match, and on the one device class that lives here (fresh install / restore, no
        // persisted schedule) the engine only learns mined-ness FROM the wallet's own scan — so
        // `.mined` keeps engine truth, and the set gates only the `.broadcast(txid:)` rows.
        confirmedTxIds: Set<String>? = nil
    ) -> [MigrationTransferRow]? {
        let transferStatuses = statuses
            .compactMap { status -> (crossing: Int, status: MigrationTransactionStatus)? in
                guard case let MigrationTransactionStatus.Kind.transfer(crossing) = status.kind else { return nil }
                return (crossing, status)
            }
            // MOB-1466 (M2): display order = broadcast SLOT, not `crossing`. `crossing` ranks
            // denominations, and the engine deliberately shuffles crossing↔slot (ZIP 318 MUST,
            // zcash_pool_migration engine.rs: broadcast order must not reveal the balance), so a
            // crossing-sorted list renders a shuffled timeline — rows visibly complete "out of
            // order". Sorting the DISPLAY by slot is chain-invisible and matches what actually
            // happens; `crossing` stays as the deterministic tiebreak for same-slot rows.
            .sorted { ($0.status.scheduledHeight, $0.crossing) < ($1.status.scheduledHeight, $1.crossing) }
            .map { $0.status }

        guard !transferStatuses.isEmpty else { return nil }

        let firstNonTerminalIndex = transferStatuses.firstIndex { status in
            switch status.state {
            case MigrationTransactionStatus.State.mined, MigrationTransactionStatus.State.broadcast:
                return false
            default:
                return true
            }
        }

        return transferStatuses.enumerated().map { index, status in
            if case MigrationTransactionStatus.State.mined = status.state {
                return MigrationTransferRow(
                    id: String(status.id),
                    index: index,
                    amount: nil,
                    status: MigrationTransferRow.Status.sent,
                    hoursFromNow: 0
                )
            }

            let minutesFromNow = MigrationETA.minutesFromNow(scheduledHeight: status.scheduledHeight, clock: clock)

            // A25 (SDK addendum §3): same precedence as `transferRows` — below `.mined`, above
            // everything else.
            if case MigrationTransactionStatus.State.invalid = status.state {
                return MigrationTransferRow(
                    id: String(status.id),
                    index: index,
                    amount: nil,
                    status: MigrationTransferRow.Status.invalid,
                    hoursFromNow: (minutesFromNow ?? 0) / 60,
                    minutesFromNow: minutesFromNow,
                    isETAKnown: minutesFromNow != nil
                )
            }

            if case let MigrationTransactionStatus.State.broadcast(txid) = status.state {
                // R11: on the chain's side, green only when the WALLET's own store has it mined —
                // the `.broadcast` payload carries the raw-order txid; the set holds display-form.
                let isWalletConfirmed = confirmedTxIds?.contains(txid.toHexStringTxId()) == true
                return MigrationTransferRow(
                    id: String(status.id),
                    index: index,
                    amount: nil,
                    status: isWalletConfirmed ? MigrationTransferRow.Status.sent : MigrationTransferRow.Status.confirming,
                    hoursFromNow: 0,
                    isBroadcasting: true
                )
            }

            if status.blockedOn == MigrationTransactionStatus.Blocker.expired {
                return MigrationTransferRow(
                    id: String(status.id),
                    index: index,
                    amount: nil,
                    status: MigrationTransferRow.Status.expired,
                    hoursFromNow: (minutesFromNow ?? 0) / 60,
                    minutesFromNow: minutesFromNow,
                    isETAKnown: minutesFromNow != nil
                )
            }

            // FIND-1 (2026-08-05): the same dependency veto `transferRows`'s lane applies — this
            // fallback lane reads the height's lateness per row, but a `blockedOn == .dependencies`
            // row is on plan, not late, and the clock's badge must not land on it.
            let isAwaitingRunDependencies = status.blockedOn == MigrationTransactionStatus.Blocker.dependencies
            let rowStatus: MigrationTransferRow.Status
            if index == firstNonTerminalIndex {
                rowStatus = (minutesFromNow ?? Int.max) > 0 || isAwaitingRunDependencies
                    ? MigrationTransferRow.Status.active
                    : MigrationTransferRow.Status.overdue
            } else {
                rowStatus = MigrationTransferRow.Status.pending
            }

            return MigrationTransferRow(
                id: String(status.id),
                index: index,
                amount: nil,
                status: rowStatus,
                hoursFromNow: (minutesFromNow ?? 0) / 60,
                minutesFromNow: minutesFromNow,
                isPreparing: isPreparing(status, isProvingStalled: isProvingStalled),
                isAwaitingRunDependencies: isAwaitingRunDependencies,
                isAwaitingAnchorBoundary: status.blockedOn == MigrationTransactionStatus.Blocker.anchorBoundary,
                // D4: real elapsed for the overdue caption, W1-fallback lane.
                overdueMinutesAgo: rowStatus == MigrationTransferRow.Status.overdue
                    ? MigrationETA.overdueMinutes(scheduledHeight: status.scheduledHeight, clock: clock)
                    : nil
            )
        }
    }

    /// D14: the run's note-PREPARATION rows, derived from the live per-transaction statuses the
    /// engine reports — the post-commit counterpart to the pre-commit count that
    /// `MigrationRunEstimate.Run.preparationTransactions` supplies.
    ///
    /// Until D14 the UI synthesized exactly ONE "Split Balance" row regardless of how many
    /// preparation transactions a run actually had. A large balance genuinely splits across several
    /// transactions and several dependency LAYERS (a split of a split), and Android has always
    /// shown them separately. One row understated both the work and the elapsed time.
    ///
    /// Ordering is `(layer, index)` — the engine's own dependency order, which is the order they
    /// broadcast in, so the rows read top-to-bottom the way they happen.
    ///
    /// Every row's `amount` is `nil`, and that is a CONTRACT not a gap: `MigrationTransactionStatus`
    /// carries no amount by design ("status rows carry no amount" — its own doc). Splitting the
    /// run's total across N rows would be invention; the timeline already renders an amount-less
    /// row correctly (trailing column collapses, row rhythm intact).
    ///
    /// Returns `nil` — not `[]` — when the statuses carry no preparation at all, so a caller can
    /// tell "no preparation data available, fall back to the synthesized row" apart from "this run
    /// genuinely has no preparation step".
    /// A14: the "Prepare Your Balance" sheet's real per-step ladder, replacing
    /// `MigrationPrepareBalanceRow.interimLadder`'s shaped placeholder. `nil` when the run reports
    /// no preparation statuses — the caller falls back to the placeholder, so a read that has not
    /// arrived yet never empties a sheet the user already opened.
    ///
    /// Ordered by (layer, index), the same order `preparationRows` uses, so a step's number here is
    /// the same step's number on the timeline.
    ///
    /// DEPENDENCIES ARE RENUMBERED. `dependsOn` carries the engine's own ids; the sheet says
    /// "Waits on steps 1 & 2", meaning DISPLAY positions. Mapping one to the other is this
    /// function's real work — and it is why an id that is not itself a preparation (a transfer this
    /// step somehow depended on) is dropped rather than rendered as a number pointing at nothing.
    ///
    /// State mapping, in precedence order — terminal facts first, then the reason for waiting
    /// (field 2026-08-05: the old `isReady -> .readyToSend` arm was schedule-blind — every pending
    /// step read "Ready to send" regardless of a turn still minutes-to-hours ahead, and no user
    /// send action exists for a preparation in the first place: the app proves and delivers it):
    /// - `.mined` -> `.done` (no forward time)
    /// - `.broadcast` -> `.sent` (no forward time — the chain is working, not a schedule)
    /// - `.invalid` -> `.invalid` (SDK addendum §3 — dead by observed event; no forward time)
    /// - `blockedOn == .dependencies` with known predecessors -> `.waitsOn([display numbers])`
    /// - scheduled turn still ahead -> `.scheduled` (the time line under the title says when;
    ///   schedule truth outranks `isReady`, which only means the PROOF can be built early)
    /// - due (turn arrived) -> `.preparing`: the app's work, whether the sweep has picked it up
    ///   yet or not — a tick is seconds away, and there is nothing for the user to do, which is
    ///   exactly what that caption says. `.waitsOn([])` also lands here ("waits on nothing" is
    ///   not a state a user can act on).
    ///
    /// THE SPINNER INVARIANT (Lukas, 2026-08-06): `isProvingStalled` joins the signature — the
    /// same verdict the sibling `preparationRows` already takes. A stall quiets the BANNER and the
    /// timeline rows, and this sheet was the one surface still spinning over a sweep that provably
    /// produces nothing (the overnight-stall class, relocated). Stalled ⇒ a due step renders
    /// `.scheduled` with no forward time — static badge, honest words, zero spinners while the
    /// banner is quiet.
    static func prepareBalanceRows(
        statuses: [MigrationTransactionStatus],
        clock: MigrationChainClock,
        isProvingStalled: Bool = false
    ) -> [MigrationPrepareBalanceRow]? {
        let ordered = statuses
            .compactMap { status -> (layer: Int, index: Int, status: MigrationTransactionStatus)? in
                guard case let MigrationTransactionStatus.Kind.preparation(layer, index) = status.kind else { return nil }
                return (layer, index, status)
            }
            .sorted { ($0.layer, $0.index) < ($1.layer, $1.index) }
            .map { $0.status }

        guard !ordered.isEmpty else { return nil }

        // Engine id -> 1-based display number, built from the same order the rows render in.
        var displayNumber: [UInt32: Int] = [:]
        for (offset, status) in ordered.enumerated() {
            displayNumber[status.id] = offset + 1
        }

        return ordered.enumerated().map { index, status in
            let forwardMinutes = MigrationETA.minutesFromNow(scheduledHeight: status.scheduledHeight, clock: clock)
            // MOB-1466: the state fork below asks "is this step's turn here yet?". With an unknown
            // tip there is no answer, and the conservative one is NO — a step whose turn cannot be
            // dated must not be described as arrived. `Int.max` reads as "still ahead" at every
            // comparison site; the row's own ETA keeps the honest `nil` and says "Recomputing ETA…".
            let forwardMinutesForState = forwardMinutes ?? Int.max
            var minutesFromNow: Int? = forwardMinutes
            let state: MigrationPrepareBalanceRow.State
            switch status.state {
            case MigrationTransactionStatus.State.mined:
                state = MigrationPrepareBalanceRow.State.done
                minutesFromNow = nil

            case MigrationTransactionStatus.State.broadcast:
                // Andrea's ladder (2026-08-03): a broadcast step reads "Sent", never "Preparing" —
                // the word "Preparing" is reserved for work the app itself is doing. No forward
                // time either: the chain is working, not a schedule.
                state = MigrationPrepareBalanceRow.State.sent
                minutesFromNow = nil

            case MigrationTransactionStatus.State.invalid:
                // SDK addendum §3. Below `.mined` for the same reason every other surface puts it
                // there — chain inclusion outranks an invalid verdict. No forward time: no chain
                // condition makes it actionable again.
                state = MigrationPrepareBalanceRow.State.invalid
                minutesFromNow = nil

            default:
                // THE SPINNER INVARIANT: a due step spins only while proving can actually happen.
                // Stalled, it reads as a quiet `.scheduled` with no time line — matching the
                // banner and the timeline rows the same verdict already quiets.
                let dueState: MigrationPrepareBalanceRow.State = isProvingStalled
                    ? MigrationPrepareBalanceRow.State.scheduled
                    : MigrationPrepareBalanceRow.State.preparing
                if isProvingStalled, forwardMinutesForState <= 0 {
                    minutesFromNow = nil
                }
                if status.blockedOn == MigrationTransactionStatus.Blocker.dependencies {
                    let waitsOn = status.dependsOn.compactMap { displayNumber[$0] }.sorted()
                    state = waitsOn.isEmpty
                        ? (forwardMinutesForState > 0
                            ? MigrationPrepareBalanceRow.State.scheduled
                            : dueState)
                        : MigrationPrepareBalanceRow.State.waitsOn(waitsOn)
                } else if forwardMinutesForState > 0 {
                    state = MigrationPrepareBalanceRow.State.scheduled
                } else {
                    state = dueState
                }
            }

            return MigrationPrepareBalanceRow(
                id: String(status.id),
                index: index,
                state: state,
                minutesFromNow: minutesFromNow
            )
        }
    }

    static func preparationRows(
        statuses: [MigrationTransactionStatus],
        clock: MigrationChainClock,
        isProvingStalled: Bool = false,
        // GROUND_RULES R11 — see `transferRows`. A preparation has no `SentRecord` and its `.mined`
        // state carries no txid, so the broadcast-time txid remembered by the manager
        // (`rememberedBroadcastTxIds`, keyed by the engine's stable status id) is the join here;
        // an id with no remembered txid keeps engine truth (the app-kill degradation, documented
        // at the cache).
        confirmedTxIds: Set<String>? = nil,
        rememberedTxIds: [UInt32: String] = [:]
    ) -> [MigrationTransferRow]? {
        let preparations = statuses
            .compactMap { status -> (layer: Int, index: Int, status: MigrationTransactionStatus)? in
                guard case let MigrationTransactionStatus.Kind.preparation(layer, index) = status.kind else { return nil }
                return (layer, index, status)
            }
            .sorted { ($0.layer, $0.index) < ($1.layer, $1.index) }

        guard !preparations.isEmpty else { return nil }

        return preparations.enumerated().map { position, preparation in
            let status = preparation.status

            // MINED per the ENGINE used to be this row's green; R11 narrows it further — a split's
            // "done" is when the WALLET's own store has observed it (same standard as every other
            // green), matched via the broadcast-time txid the manager remembered. Engine mined-ness
            // still drives the run's DEPENDENCIES (a merely-broadcast split has not created the
            // spendable notes its transfers wait on) — that is the engine's side, untouched here.
            if case MigrationTransactionStatus.State.mined = status.state {
                let isWalletConfirmed: Bool
                if let confirmedTxIds, let txId = rememberedTxIds[status.id] {
                    isWalletConfirmed = confirmedTxIds.contains(txId)
                } else {
                    // No wallet read ever, or no remembered txid to match — engine truth stands.
                    isWalletConfirmed = true
                }
                return MigrationTransferRow(
                    id: String(status.id),
                    index: position,
                    amount: nil,
                    status: isWalletConfirmed ? MigrationTransferRow.Status.sent : MigrationTransferRow.Status.confirming,
                    hoursFromNow: 0,
                    kind: MigrationTransferRow.Kind.splitBalance
                )
            }

            let minutesFromNow = MigrationETA.minutesFromNow(scheduledHeight: status.scheduledHeight, clock: clock)

            // E2E harness F#1b (2026-08-04): this derivation never checked `.invalid`, so an
            // unsatisfiable preparation fell through to `.active` — the timeline read "ready" and
            // the poke armer treated it as the next send, for a row the engine knows can never
            // broadcast (field DB: all 4 preps `signed` + `inputs_spent`/`inherited`, rendered
            // P1–P4:ready). Same precedence as every other rows derivation (A25, SDK addendum §3):
            // below `.mined`, above everything else.
            if case MigrationTransactionStatus.State.invalid = status.state {
                return MigrationTransferRow(
                    id: String(status.id),
                    index: position,
                    amount: nil,
                    status: MigrationTransferRow.Status.invalid,
                    hoursFromNow: (minutesFromNow ?? 0) / 60,
                    minutesFromNow: minutesFromNow,
                    kind: MigrationTransferRow.Kind.splitBalance,
                    isETAKnown: minutesFromNow != nil
                )
            }

            if case let MigrationTransactionStatus.State.broadcast(txid) = status.state {
                // R11: on the chain's side — `.confirming` until the wallet's store has it mined.
                let isWalletConfirmed = confirmedTxIds?.contains(txid.toHexStringTxId()) == true
                return MigrationTransferRow(
                    id: String(status.id),
                    index: position,
                    amount: nil,
                    status: isWalletConfirmed ? MigrationTransferRow.Status.sent : MigrationTransferRow.Status.confirming,
                    hoursFromNow: 0,
                    isBroadcasting: true,
                    kind: MigrationTransferRow.Kind.splitBalance
                )
            }

            if status.blockedOn == MigrationTransactionStatus.Blocker.expired {
                return MigrationTransferRow(
                    id: String(status.id),
                    index: position,
                    amount: nil,
                    status: MigrationTransferRow.Status.expired,
                    hoursFromNow: (minutesFromNow ?? 0) / 60,
                    minutesFromNow: minutesFromNow,
                    kind: MigrationTransferRow.Kind.splitBalance,
                    isETAKnown: minutesFromNow != nil
                )
            }

            return MigrationTransferRow(
                id: String(status.id),
                index: position,
                amount: nil,
                status: MigrationTransferRow.Status.active,
                hoursFromNow: (minutesFromNow ?? 0) / 60,
                minutesFromNow: minutesFromNow,
                isPreparing: isPreparing(status, isProvingStalled: isProvingStalled),
                kind: MigrationTransferRow.Kind.splitBalance
            )
        }
    }
}

// MARK: - Persistence

/// `UserDefaults`-backed persistence for every app-owned migration flag. It used to carry the
/// app-owned half of the sync<->send privacy gate math (MOB-1496 W3) as well — a completed sync
/// briefly disabling migration sends — but both timed halves of that gate were deleted 2026-08-07,
/// so nothing here measures a window any more. The surviving hold is the SDK's own present-tense
/// one (`isMigrationSyncBlocked`/`migrationSyncBlockedStream`), not this class. Every method that
/// depends on "now" takes it as a parameter — never reads `Date()` internally — so tests can drive
/// the clock explicitly. Injectable `UserDefaults` (default `.standard`) lets tests use an isolated
/// named suite.
final class MigrationGateStorage: @unchecked Sendable {
    /// MOB-1496: the SDK's `MigrationNetworkPrivacyOptions` isn't `Codable` (it carries a
    /// `LightWalletEndpoint`) — only the persisted `useTor` choice is stored here, under the SAME
    /// UserDefaults key/JSON shape as before (minimally migrated: the old payload also carried a
    /// now-dropped `submissionEndpoint: String?`). MOB-1496 (W4): this stored choice is consumed
    /// once, the first time a run's `MigrationNetworkSnapshot` is taken — see
    /// `MigrationManagerImpl.createNetworkSnapshot()`.
    private struct PersistedNetworkPrivacyOptions: Codable {
        var useTor: Bool
    }

    private let userDefaults: UserDefaults
    /// R8-T3 (S2): the completion-acknowledged flag is per-account now — everything else about a
    /// migration run already is (state, schedule, snapshot), so a wallet-wide flag suppressed a
    /// SECOND account's own completion banner/re-entry the moment the FIRST account acknowledged,
    /// made that second account's own `acknowledgeComplete` unreachable (its call sites sit behind
    /// the suppressed screens), and left its snapshot immortal (only `.notStarted` triggers the
    /// automatic clear, but `.complete` is terminal). Same generic storage, same hex-key idiom as
    /// `MigrationScheduleStorage`/`MigrationSnapshotStorage` (R8-T3 #21) — reuses the OLD wallet-wide
    /// key string as its per-account PREFIX; the bare (unsuffixed) legacy key is simply never
    /// written or read by this storage again (see `resetPersistedFlags()`, which still deletes the
    /// legacy key for hygiene). No migration of the old value: the feature is unreleased
    /// (dev/QA installs only), so "migrated on first read" is satisfied vacuously.
    private let acknowledgedStorage: PerAccountCodableStorage<Bool>
    /// MOB-1496: per-account, tri-state migration-remainder verdict — `nil` (no persisted payload)
    /// means "never evaluated since the account last left `.complete`"; `PerAccountCodableStorage
    /// .read(for:)` already returns the raw `Bool?` (no `?? false` folded in at this layer), which
    /// is exactly the tri-state `remainderPending(for:)` below needs to preserve. Same generic
    /// storage / hex-key idiom as `acknowledgedStorage` beside it.
    private let remainderStorage: PerAccountCodableStorage<Bool>
    /// MOB-1511 (W2): per-account count of COMPLETED migration runs — drives the "Round N" labels
    /// on the transfer plan and the Home banner for multi-round (sequential-run) migrations.
    private let completedRoundsStorage: PerAccountCodableStorage<Int>
    /// MOB-1509: per-account — two concurrently migrating accounts (software + Keystone) choose
    /// their migration mode independently; the old wallet-wide keys let the second account's
    /// choice clobber the first's. Same legacy-key-as-prefix idiom as above.
    private let modeStorage: PerAccountCodableStorage<MigrationMode>

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.acknowledgedStorage = PerAccountCodableStorage<Bool>(
            keyPrefix: .migrationCompleteAcknowledged,
            corruptLogTag: "MigrationGateStorage.acknowledgedStorage",
            userDefaults: userDefaults
        )
        self.remainderStorage = PerAccountCodableStorage<Bool>(
            keyPrefix: .migrationRemainderPending,
            corruptLogTag: "MigrationGateStorage.remainderStorage",
            userDefaults: userDefaults
        )
        self.completedRoundsStorage = PerAccountCodableStorage<Int>(
            keyPrefix: .migrationCompletedRounds,
            corruptLogTag: "MigrationGateStorage.completedRoundsStorage",
            userDefaults: userDefaults
        )
        self.modeStorage = PerAccountCodableStorage<MigrationMode>(
            keyPrefix: .migrationMode,
            corruptLogTag: "MigrationGateStorage.modeStorage",
            userDefaults: userDefaults
        )
    }

    // (The gate section — `recordSyncCompleted(at:)`, `sendGate(now:buffer:)` and the
    // `migrationLastSyncCompletedAt` timestamp they shared — was deleted 2026-08-07 with the
    // app-side post-sync privacy buffer. Nothing measures a window from a completed sync any
    // more, so there is no timestamp left to persist; see `MigrationManagerInterface`'s header
    // for the ruling. `wipeEverything()` below still clears the stale key by prefix sweep, which
    // is how an upgraded install sheds it.)

    // MARK: Mode / network privacy / acknowledge / dust-lock

    func migrationMode(for accountUUID: AccountUUID) -> MigrationMode? {
        modeStorage.read(for: accountUUID)
    }

    func setMigrationMode(_ mode: MigrationMode, for accountUUID: AccountUUID) {
        modeStorage.write(mode, for: accountUUID)
    }

    func clearMigrationMode(for accountUUID: AccountUUID) {
        modeStorage.clear(for: accountUUID)
    }

    /// Only `useTor` is persisted — see `PersistedNetworkPrivacyOptions`'s doc.
    /// `MigrationManagerImpl.createNetworkSnapshot()` reads this once, when a run's
    /// `MigrationNetworkSnapshot` is first taken, and combines it with the app's then-current sync
    /// endpoint.
    ///
    /// MOB-1497 (R1): defaults to `true`, not `false`, when never written — Tor is on by default for
    /// a provider user. The sheet's own visual default is already ON (`MigrationTorSheet.State
    /// .isTorOn`); this closes the belt-and-braces gap where a broadcast could theoretically read an
    /// implicit false (e.g. a lane that reaches a broadcast before the sheet has ever written a
    /// choice). The identity-custom forced-false in `createNetworkSnapshot` still wins over this for
    /// a custom sync server, same as it would over an explicit stored `true`.
    func isTorEnabledForMigration() -> Bool {
        guard let data = userDefaults.data(forKey: .migrationNetworkPrivacyOptions),
              let stored = try? JSONDecoder().decode(PersistedNetworkPrivacyOptions.self, from: data) else {
            return true
        }

        return stored.useTor
    }

    func setTorEnabledForMigration(_ useTor: Bool) {
        guard let data = try? JSONEncoder().encode(PersistedNetworkPrivacyOptions(useTor: useTor)) else { return }
        userDefaults.set(data, forKey: .migrationNetworkPrivacyOptions)
    }

    /// R8-T3 (S2): per-account now — see `acknowledgedStorage`'s doc.
    func isCompleteAcknowledged(for accountUUID: AccountUUID) -> Bool {
        acknowledgedStorage.read(for: accountUUID) ?? false
    }

    func acknowledgeComplete(for accountUUID: AccountUUID) {
        acknowledgedStorage.write(true, for: accountUUID)
    }

    func clearAcknowledgedComplete(for accountUUID: AccountUUID) {
        acknowledgedStorage.clear(for: accountUUID)
    }

    /// MOB-1496: the raw tri-state verdict — `nil` when never evaluated since `accountUUID` last
    /// left `.complete` (deliberately NOT folded to `?? false` here; `reconcile()`'s
    /// evaluate-exactly-once gate and `MigrationManagerImpl.isMigrationRemainderPending`'s
    /// client-facing `false` fallback both need to tell "never evaluated" apart from "evaluated,
    /// genuinely nothing pending" — folding it away at this layer would erase that distinction for
    /// everyone downstream).
    func remainderPending(for accountUUID: AccountUUID) -> Bool? {
        remainderStorage.read(for: accountUUID)
    }

    /// Persists a completed evaluation's verdict — see `MigrationManagerImpl
    /// .evaluateMigrationRemainder`'s doc for the ONE call site that invokes this (and why only
    /// once per completion transition).
    func setRemainderPending(_ pending: Bool, for accountUUID: AccountUUID) {
        remainderStorage.write(pending, for: accountUUID)
    }

    /// Invalidates the verdict — called the moment `accountUUID` leaves `.complete` (right beside
    /// `clearAcknowledgedComplete` in `reconcile()`), so the NEXT time it reaches `.complete` (this
    /// run continuing, or a later logical run) gets its own fresh evaluation rather than inheriting
    /// a stale one.
    func clearRemainderPending(for accountUUID: AccountUUID) {
        remainderStorage.clear(for: accountUUID)
    }

    /// MOB-1511 (W2): how many runs ("rounds") `accountUUID` has COMPLETED — incremented exactly
    /// once per completion transition (beside `reconcile()`'s remainder evaluation, which shares
    /// the same exactly-once gate). The user-facing round number of the run in flight is
    /// `completedRounds + 1`.
    func completedRounds(for accountUUID: AccountUUID) -> Int {
        completedRoundsStorage.read(for: accountUUID) ?? 0
    }

    func incrementCompletedRounds(for accountUUID: AccountUUID) {
        completedRoundsStorage.write(completedRounds(for: accountUUID) + 1, for: accountUUID)
    }

    func clearCompletedRounds(for accountUUID: AccountUUID) {
        completedRoundsStorage.clear(for: accountUUID)
    }

    /// Clears every WALLET-WIDE persisted migration flag this storage owns: mode, manual delivery,
    /// network privacy, PLUS the legacy (pre-R8-T3, unsuffixed) complete-acknowledged key — dead
    /// weight now that the flag is per-account (`acknowledgedStorage`), kept here only so no stray
    /// value lingers. The actual per-account acknowledged flags are cleared by
    /// `MigrationManagerImpl.resetPersistedFlags()`, which knows the account set this storage does
    /// not. Backs the test-only "Reset app migration flags" reset (`MigrationManagerTests`/
    /// `MigrationFailureRoutingTests`).
    /// MOB-1496 (W-A): no longer touches `.migrationDustLocked` — "Lock balance" is now a genuine
    /// SDK-side lock (`PoolBalance.lockedValue`), not app-persisted storage, so there is no local
    /// dust-locked flag left to clear.
    func resetPersistedFlags() {
        userDefaults.removeObject(forKey: .migrationMode)
        userDefaults.removeObject(forKey: .migrationNetworkPrivacyOptions)
        userDefaults.removeObject(forKey: .migrationCompleteAcknowledged)
    }

    /// EVERY migration key this app has ever written, by prefix — the wallet-reset wipe (MOB-1466
    /// N3, field-caught 2026-08-01: a notification armed by the previous wallet fired after a reset
    /// and a fresh restore).
    ///
    /// Deliberately a prefix sweep and not a list. `resetPersistedFlags()` above is a list, and it
    /// is exactly four of the eighteen `sharedStateKey_migration*` keys — the four someone
    /// remembered. Every per-account key is that prefix plus an account-hex suffix, so a list
    /// cannot name them at all, and every future key would have to be added by hand to a call site
    /// nobody thinks about while adding one. A reset that misses a key does not fail loudly; it
    /// hands the next wallet a stranger's state.
    ///
    /// The prefix sweep is also what sheds `migrationLastSyncCompletedAt`, the stamp the retired
    /// post-sync send buffer measured from: nothing writes it any more, so an upgraded install
    /// simply carries a dead key until some wipe collects it.
    ///
    /// Same shape as the voting wipe in `Root.clearDeviceScopedWalletState`, and for the same
    /// stated reason: nothing from the previous owner of this device may survive the reset
    /// boundary.
    func wipeEverything() {
        for key in userDefaults.dictionaryRepresentation().keys where key.hasPrefix(Self.migrationKeyPrefix) {
            userDefaults.removeObject(forKey: key)
        }
    }

    /// The prefix every `SharedStateKeys` migration constant starts with — per-account keys append
    /// an account-hex suffix to one of them.
    private static let migrationKeyPrefix = "sharedStateKey_migration"
}

// MARK: - Persistence: generic per-account Codable storage (R8-T3 #21)

/// Generic `UserDefaults`-backed per-account persistence — the shared shape `MigrationScheduleStorage`
/// and `MigrationSnapshotStorage` each independently implemented before this extraction (lock, keyed
/// read, clear, corrupt-blob self-heal, `writePayload`, hex `key(for:)`), now also reused by
/// `MigrationGateStorage`'s per-account acknowledge flag (R8-T3 S2). `final class`, `@unchecked
/// Sendable` guarded by an `OSAllocatedUnfairLock` around each read-modify-write, injectable
/// `UserDefaults` (default `.standard`) so tests can use an isolated named suite. `keyPrefix` is the
/// caller's own `SharedStateKeys` (`String`) constant; `corruptLogTag` names the caller in the
/// self-heal log line, matching each original type's own tag.
final class PerAccountCodableStorage<Payload: Codable & Sendable>: @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let keyPrefix: String
    private let corruptLogTag: String
    private let lock = OSAllocatedUnfairLock(initialState: false)

    init(keyPrefix: String, corruptLogTag: String, userDefaults: UserDefaults = .standard) {
        self.keyPrefix = keyPrefix
        self.corruptLogTag = corruptLogTag
        self.userDefaults = userDefaults
    }

    /// The persisted payload for `accountUUID`, or `nil` when none exists (or the stored blob was
    /// corrupt and just got self-healed away).
    func read(for accountUUID: AccountUUID) -> Payload? {
        lock.withLock { _ in readPayload(for: accountUUID) }
    }

    /// Persists `payload` for `accountUUID`, REPLACING any existing one unconditionally. Callers
    /// needing a read-modify-write (preserve part of the existing payload, or conditionally clear)
    /// should use `modify(for:_:)` instead — this alone is not atomic with a prior `read(for:)`.
    func write(_ payload: Payload, for accountUUID: AccountUUID) {
        lock.withLock { _ in writePayload(payload, for: accountUUID) }
    }

    /// Clears the persisted payload for `accountUUID`.
    func clear(for accountUUID: AccountUUID) {
        lock.withLock { _ in
            userDefaults.removeObject(forKey: key(for: accountUUID))
        }
    }

    /// Atomic read-modify-write: `body` receives the CURRENT payload (`nil` if none/corrupt) as an
    /// `inout`, under the SAME lock acquisition the read and the eventual write both use — no
    /// concurrent `read`/`write`/`clear`/`modify` call for this account can observe a half-updated
    /// value or interleave between the read `body` sees and the write/clear it produces. Setting the
    /// `inout` value to `nil` inside `body` clears the persisted payload instead of writing one.
    ///
    /// `body` may return a value, propagated back through `modify` itself — MOB-1497 (R9-T6): lets
    /// a caller (`MigrationSnapshotStorage.ensureOrCreate`) report which value it decided on
    /// (existing vs. a freshly-written candidate) from INSIDE the same atomic section, without
    /// capturing an outer `var` into the `@Sendable` closure (the Swift 6 concurrency checker
    /// disallows mutating a captured `var` from inside a `@Sendable` closure even when, as here,
    /// the closure is actually invoked synchronously and non-escaping). Every pre-existing call
    /// site's closure has no `return <value>` statement, so `T` continues to infer as `Void` for
    /// them — this is a purely additive, backward-compatible signature widening.
    @discardableResult
    func modify<T: Sendable>(for accountUUID: AccountUUID, _ body: @Sendable (inout Payload?) -> T) -> T {
        lock.withLock { _ in
            var payload = readPayload(for: accountUUID)
            let result = body(&payload)
            if let payload {
                writePayload(payload, for: accountUUID)
            } else {
                userDefaults.removeObject(forKey: key(for: accountUUID))
            }
            return result
        }
    }

    private func readPayload(for accountUUID: AccountUUID) -> Payload? {
        let storageKey = key(for: accountUUID)
        guard let data = userDefaults.data(forKey: storageKey) else { return nil }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            // Self-heal: an undecodable blob would otherwise return `nil` forever while the
            // garbage stays on disk. Delete it so the next write starts clean.
            LoggerProxy.error("[\(corruptLogTag)] Corrupt payload — deleting the stored blob.")
            userDefaults.removeObject(forKey: storageKey)
            return nil
        }
        return payload
    }

    private func writePayload(_ payload: Payload, for accountUUID: AccountUUID) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: key(for: accountUUID))
    }

    /// Per-account key suffix: lowercase hex of the raw 16-byte UUID, reusing `Pczt`'s existing
    /// `Data.hexEncodedString()` (`SendConfirmationStore.swift`) rather than inventing a new
    /// encoding.
    private func key(for accountUUID: AccountUUID) -> String {
        "\(keyPrefix)_\(Data(accountUUID.id).hexEncodedString())"
    }
}

// MARK: - Persistence: committed migration schedule (MOB-1496 W2)

/// Per-account persistence for the confirmed migration schedule: the SDK retains no proposal list
/// once a schedule is committed, so the app persists it here — `MigrationDerivations
/// .transferRows`/`summary` derive rows/totals from this payload plus live SDK reads. R8-T3 (#21):
/// now a thin wrapper over the shared `PerAccountCodableStorage` (lock, keyed read, clear,
/// corrupt-blob self-heal all live there); this type keeps only its own domain-specific
/// read-modify-write semantics (preserve `sentRecords` across a re-commit; append a `SentRecord` in
/// schedule order). Every method that depends on "now" takes it as a parameter, never reading
/// `Date()` internally, matching `MigrationGateStorage`'s own testability discipline.
final class MigrationScheduleStorage: @unchecked Sendable {
    private let storage: PerAccountCodableStorage<MigrationCommittedSchedule>

    init(userDefaults: UserDefaults = .standard) {
        self.storage = PerAccountCodableStorage<MigrationCommittedSchedule>(
            keyPrefix: .migrationCommittedSchedule,
            corruptLogTag: "MigrationScheduleStorage",
            userDefaults: userDefaults
        )
    }

    /// The persisted payload for `accountUUID`, or `nil` when none exists (fresh install mid-run,
    /// or pre-commit) — callers fall back to a progress-only derivation in that case.
    func committedSchedule(for accountUUID: AccountUUID) -> MigrationCommittedSchedule? {
        storage.read(for: accountUUID)
    }

    func hasStoredPayload(for accountUUID: AccountUUID) -> Bool {
        committedSchedule(for: accountUUID) != nil
    }

    /// MOB-1466: THE ONLY WRITER of `cancelledByUserAt`. Called from Restart Migration's own
    /// confirm, after the engine's cancel returns — nothing else in the app may set this, which is
    /// what keeps "Migration required" impossible to reach by accident.
    ///
    /// A no-op when no payload exists: without a stored run there is nothing to have cancelled, and
    /// inventing a payload here would fabricate a run that never was.
    func markRunCancelledByUser(for accountUUID: AccountUUID, now: Date) {
        storage.modify(for: accountUUID) { payload in
            payload?.cancelledByUserAt = now
        }
    }

    /// Whether THIS stored run was cancelled by the user. Cleared implicitly by
    /// `recordCommittedSchedule`, which replaces the payload with a fresh one — a newly committed
    /// plan is a new run and inherits nothing.
    func wasRunCancelledByUser(for accountUUID: AccountUUID) -> Bool {
        committedSchedule(for: accountUUID)?.cancelledByUserAt != nil
    }

    /// REPLACES `schedule`/`committedAt`; PRESERVES `sentRecords` from any existing payload (a
    /// restart/re-created plan continues the same logical run — the re-created-plan UI shows prior
    /// sent rows with checks); starts fresh with empty `sentRecords` when no payload exists yet.
    func recordCommittedSchedule(_ schedule: MigrationSchedule, for accountUUID: AccountUUID, now: Date) {
        storage.modify(for: accountUUID) { payload in
            let sentRecords = payload?.sentRecords ?? []
            payload = MigrationCommittedSchedule(schedule: schedule, sentRecords: sentRecords, committedAt: now)
        }
    }

    /// Appends a `SentRecord` for the broadcast transfer, on `.success(txId:)` only — every other
    /// result, and a missing payload (nothing to append against), is a no-op. An empty `txId` (the
    /// record-failed-after-broadcast placeholder — the broadcast landed, only the engine's own
    /// recording of it failed) persists as `nil` rather than an empty string.
    ///
    /// MOB-1466 (M2, SDK delegation): `transferId` is the transfer the delivery lane ACTUALLY
    /// served, resolved by the manager layer (live-status txid match, else the D6 in-flight
    /// marker). When it names a not-yet-recorded schedule row, the record is appended against that
    /// row. The legacy guess — the first row in the persisted array with no sent record — remains
    /// only as the `nil`/unmatched fallback: the engine delivers in schedule-SLOT order (and
    /// rebuilds/withholds can reorder further), while the persisted array carries crossing order,
    /// so a positional guess can attribute a landed broadcast to the wrong transfer — wrong row
    /// green, wrong amount, txid keyed to the wrong id for R11's wallet-confirmation match.
    func recordTransferBroadcast(_ result: MigrationTransferResult, transferId: UInt32?, for accountUUID: AccountUUID, now: Date) {
        storage.modify(for: accountUUID) { payload in
            guard case let MigrationTransferResult.success(txId) = result else { return }
            guard var current = payload else { return }

            let sentTransferIds = Set(current.sentRecords.map { $0.transferId })
            let identified = transferId.flatMap { servedId in
                current.schedule.transfers.first { $0.transferKey == String(servedId) && !sentTransferIds.contains($0.transferKey) }
            }
            if transferId != nil && identified == nil {
                // Said, not silent (the file's own discipline): a resolved id that the persisted
                // schedule cannot place (stale/refreshed payload, or already recorded) degrades to
                // the legacy positional guess rather than dropping a landed broadcast's record.
                LoggerProxy.warn("[MigrationScheduleStorage] served transfer id not in the persisted schedule (or already recorded) — falling back to the positional guess")
            }
            guard let transfer = identified ?? current.schedule.transfers.first(where: { !sentTransferIds.contains($0.transferKey) }) else { return }

            let sentRecord = MigrationCommittedSchedule.SentRecord(
                transferId: transfer.transferKey,
                amount: transfer.amount,
                txId: txId.isEmpty ? nil : txId,
                sentAt: now
            )
            current.sentRecords.append(sentRecord)
            payload = current
        }
    }

    /// Clears the run: consumed by `acknowledgeComplete()`/`resetPersistedFlags()`'s run-end/reset
    /// paths, and by `reconcile()` observing a stale `.notStarted` payload.
    func clear(for accountUUID: AccountUUID) {
        storage.clear(for: accountUUID)
    }
}

// MARK: - Persistence: migration network snapshot (MOB-1496 W4)

/// Per-account persistence for the atomic migration network snapshot — see `MigrationNetworkSnapshot`'s
/// doc for what it holds and why. R8-T3 (#21): thin wrapper over the shared `PerAccountCodableStorage`
/// (beside which this lives) — this type is now just naming/typing, no storage mechanics of its own.
final class MigrationSnapshotStorage: @unchecked Sendable {
    private let storage: PerAccountCodableStorage<MigrationNetworkSnapshot>

    init(userDefaults: UserDefaults = .standard) {
        self.storage = PerAccountCodableStorage<MigrationNetworkSnapshot>(
            keyPrefix: .migrationNetworkSnapshot,
            corruptLogTag: "MigrationSnapshotStorage",
            userDefaults: userDefaults
        )
    }

    /// The persisted snapshot for `accountUUID`, or `nil` when none exists (no active run, or a run
    /// whose snapshot was already cleared at completion).
    func snapshot(for accountUUID: AccountUUID) -> MigrationNetworkSnapshot? {
        storage.read(for: accountUUID)
    }

    /// Persists `snapshot` for `accountUUID`, REPLACING any existing one unconditionally — a plain
    /// write with no reuse/atomicity semantics of its own. MOB-1497 (R9-T6): `MigrationManagerImpl`'s
    /// ensure-or-create callers go through `ensureOrCreate(candidate:reformIfProvisional:for:)` below
    /// instead, which performs the atomic decide-and-write; this remains the raw primitive (used
    /// directly by tests to seed a starting snapshot).
    func recordSnapshot(_ snapshot: MigrationNetworkSnapshot, for accountUUID: AccountUUID) {
        storage.write(snapshot, for: accountUUID)
    }

    /// MOB-1497 (R9-T6, finding 8): atomic ensure-or-create for
    /// `MigrationManagerImpl.ensureOrCreateNetworkSnapshot`'s create path — closes the "check absent
    /// -> create -> write" race between two concurrent formers for the SAME account now that forming
    /// no longer serializes through `transactionGuard` (see that method's doc for why it never
    /// actually needed to). `candidate` is computed by the CALLER before this call (the `await`s on
    /// `zcashSDKEnvironment`/`migrationRandomness` must not run inside `PerAccountCodableStorage`'s
    /// synchronous `modify` closure — this method's own body never awaits anything); already stamped
    /// committed by the caller when `stampCommitted` applies. This method's body is the ONE atomic
    /// decide-and-write: it RE-CHECKS the exact same reuse condition
    /// `ensureOrCreateNetworkSnapshot` already checked before computing `candidate` — existing
    /// `committedAt != nil`, or `reformIfProvisional` is false — against whatever is ACTUALLY
    /// persisted at the instant the lock is held, not the (possibly now-stale) read that motivated
    /// computing `candidate` in the first place. A competing former that already wrote AND satisfies
    /// the condition wins: `candidate` is discarded and the existing payload is kept, untouched.
    /// Otherwise `candidate` is written. Either way, returns whatever ends up persisted — never an
    /// unstored `candidate` a concurrent write has already superseded.
    func ensureOrCreate(
        candidate: MigrationNetworkSnapshot,
        reformIfProvisional: Bool,
        for accountUUID: AccountUUID
    ) -> MigrationNetworkSnapshot {
        storage.modify(for: accountUUID) { payload in
            if let existing = payload, existing.committedAt != nil || !reformIfProvisional {
                return existing
            }
            payload = candidate
            return candidate
        }
    }

    /// Clears the run's snapshot: consumed by the SAME run-end paths `MigrationScheduleStorage.clear`
    /// is (`acknowledgeComplete()`/`resetPersistedFlags()`/`clearAbandonedNetworkSnapshot()`) —
    /// always alongside the schedule clear (except the abandon-clear, which by design has no
    /// schedule to clear — see that method's doc).
    ///
    /// MOB-1497: `acknowledgeComplete()`/`resetPersistedFlags()` still call this unconditional clear
    /// directly (a genuine run-end/reset always wipes, committed or not) — only `reconcile()`'s
    /// stale-`.notStarted` observation was moved onto `clearIfCommitted` below, since THAT path can
    /// race a still-provisional in-flight formation. See `clearIfCommitted`/`clearIfProvisional`.
    func clear(for accountUUID: AccountUUID) {
        storage.clear(for: accountUUID)
    }

    /// MOB-1497: stamps `accountUUID`'s persisted snapshot committed (`committedAt = now`) — a no-op
    /// when no snapshot is persisted, or when it is already committed (idempotent: `committedAt`
    /// only ever moves nil -> a date, never back, so a second stamp must not overwrite the FIRST
    /// commit's timestamp with a later one). Atomic read-mutate-write via the generic's `modify`
    /// (R8-T3 #21 rebase — the hand-rolled lock/read/write this was written against is gone).
    func markCommitted(for accountUUID: AccountUUID, now: Date) {
        storage.modify(for: accountUUID) { payload in
            guard var existing = payload, existing.committedAt == nil else { return }
            existing.committedAt = now
            payload = existing
        }
    }

    /// MOB-1497: clears `accountUUID`'s persisted snapshot ONLY when it is already COMMITTED
    /// (`committedAt != nil`) — a no-op against a still-provisional one, or when none is persisted.
    /// Used by `reconcile()`'s stale-`.notStarted` observation, which is a BACKGROUND tick that must
    /// not wipe a snapshot a user just formed by reaching the Tor-choice step (state is still
    /// `.notStarted` at that point — nothing has been proposed/committed yet) out from under them.
    func clearIfCommitted(for accountUUID: AccountUUID) {
        storage.modify(for: accountUUID) { payload in
            guard let existing = payload, existing.committedAt != nil else { return }
            payload = nil
        }
    }

    /// MOB-1497 (T2): mutates ONLY `useTor` on `accountUUID`'s persisted snapshot, but ONLY while it
    /// is still PROVISIONAL (`committedAt == nil`) — every other field (notably `broadcastEndpoint`)
    /// is left byte-for-byte untouched, and nothing is re-formed/re-rolled: this REPLACES the whole
    /// persisted value with a fresh `MigrationNetworkSnapshot` copied field-for-field from the
    /// existing one except `useTor`, rather than mutating `useTor` in place (it stays a `let` —
    /// unlike `committedAt`, which is the one field this type ever mutates in place). A no-op
    /// (logged) against an already-committed snapshot or when none is persisted — a live confirm
    /// should always find the provisional snapshot `formNetworkSnapshot` formed moments earlier at
    /// presentation, so reaching either branch here signals a caller ordering bug worth surfacing.
    func updateUseTorIfProvisional(_ useTor: Bool, for accountUUID: AccountUUID) {
        storage.modify(for: accountUUID) { payload in
            guard let existing = payload, existing.committedAt == nil else {
                LoggerProxy.warn(
                    "[MigrationSnapshotStorage] confirmProvisionalTorChoice: no provisional snapshot to update — ignoring."
                )
                return
            }
            payload = MigrationNetworkSnapshot(
                useTor: useTor,
                syncEndpoint: existing.syncEndpoint,
                broadcastEndpoint: existing.broadcastEndpoint,
                takenAt: existing.takenAt,
                committedAt: existing.committedAt
            )
        }
    }

    /// MOB-1497: clears `accountUUID`'s persisted snapshot ONLY when it is still PROVISIONAL
    /// (`committedAt == nil`) — a no-op against an already-committed one, or when none is persisted.
    /// Used at migration flow teardown: leaving the flow without ever committing a schedule discards
    /// the provisional pick, so a re-entry re-forms and re-rolls rather than resuming a stale one.
    func clearIfProvisional(for accountUUID: AccountUUID) {
        storage.modify(for: accountUUID) { payload in
            guard let existing = payload, existing.committedAt == nil else { return }
            payload = nil
        }
    }

    // MARK: - MOB-1497 (R7-T3, R7-review fix Important-1): sanctioned ACTIVE-snapshot mutations
    // (R14/R16/R17)
    //
    // The three doc-sanctioned exceptions to R4's run-immutability that a failure-routing surface
    // may perform — see `MigrationManagerClient.overrideTorForRun`/`.overrideBroadcastEndpointTo
    // SyncServer` and `MigrationManagerImpl.routeBroadcastFailure`'s own doc for each requirement.
    // Same shape as `updateUseTorIfProvisional` above (atomic via the generic storage's `modify`,
    // no-op + `LoggerProxy.warn` when there is nothing to mutate), but UNLIKE it these apply to the
    // account's ACTIVE snapshot — the COMMITTED one if present, else the still-PROVISIONAL one —
    // rather than only ever a provisional one. (Rebased onto R8-T3: replace-with-copy now spells
    // only the four stored fields — the providers are computed off the endpoints.)
    //
    // R7-review fix (Important-1): originally committed-only. That left the live Keystone note-split
    // lane — whose broadcast (and therefore its first R14/R16/R17 failure) happens BEFORE its
    // snapshot commits, by design — with no sanctioned mutation to apply even once
    // `routeBroadcastFailure`'s own guard was widened; a rotation/override attempted against that
    // lane's still-provisional snapshot would have silently no-op'd. A mutation applied here to a
    // still-provisional snapshot is carried forward automatically: `markCommitted` above stamps
    // whatever is CURRENTLY persisted, mutated or not, so the choice survives the commit. No-op +
    // `LoggerProxy.warn` only when NEITHER a committed nor a provisional snapshot exists at all.

    /// R14: mutates ONLY `useTor` on `accountUUID`'s ACTIVE (committed-else-provisional) snapshot —
    /// the R11-warning-gated exception to R4 for "Tor unavailable on the first broadcast of the run."
    /// Endpoint/takenAt/committedAt are left byte-for-byte untouched. A no-op (logged) only
    /// when no snapshot — committed or provisional — is persisted for the account at all.
    func overrideUseTorOnActiveSnapshot(_ useTor: Bool, for accountUUID: AccountUUID) {
        storage.modify(for: accountUUID) { payload in
            guard let existing = payload else {
                LoggerProxy.warn("[MigrationSnapshotStorage] overrideTorForRun: no active snapshot to update — ignoring.")
                return
            }
            payload = MigrationNetworkSnapshot(
                useTor: useTor,
                syncEndpoint: existing.syncEndpoint,
                broadcastEndpoint: existing.broadcastEndpoint,
                takenAt: existing.takenAt,
                committedAt: existing.committedAt
            )
        }
    }

    /// R16: mutates ONLY `broadcastEndpoint` on `accountUUID`'s ACTIVE (committed-else-provisional)
    /// snapshot — the sanctioned within-provider rotation after an unreachable broadcast endpoint.
    /// The broadcast PROVIDER is unchanged by construction: `routeBroadcastFailure` (the sole
    /// caller) only ever offers a same-provider candidate here (and the provider is computed off
    /// the endpoint's own host). A no-op (logged) only when no snapshot — committed or provisional
    /// — is persisted for the account at all. Internal to `routeBroadcastFailure` — deliberately
    /// not a `MigrationManagerClient` member (nothing else in the app needs to trigger a rotation
    /// directly).
    func rotateBroadcastEndpoint(to endpoint: MigrationNetworkSnapshot.Endpoint, for accountUUID: AccountUUID) {
        storage.modify(for: accountUUID) { payload in
            guard let existing = payload else {
                LoggerProxy.warn("[MigrationSnapshotStorage] rotateBroadcastEndpoint: no active snapshot to update — ignoring.")
                return
            }
            payload = MigrationNetworkSnapshot(
                useTor: existing.useTor,
                syncEndpoint: existing.syncEndpoint,
                broadcastEndpoint: endpoint,
                takenAt: existing.takenAt,
                committedAt: existing.committedAt
            )
        }
    }

    /// R17: sets `broadcastEndpoint := syncEndpoint` on `accountUUID`'s ACTIVE
    /// (committed-else-provisional) snapshot (the broadcast provider follows computed, becoming the
    /// sync provider) — the sanctioned consent-gated fallback once every shipped endpoint for the
    /// broadcast provider is unreachable. Afterwards the snapshot is same-server by construction,
    /// so a LATER endpoint-class failure takes `routeBroadcastFailure`'s same-server exemption
    /// (`.plainRetry`) naturally. A no-op (logged) only when no snapshot — committed or provisional
    /// — is persisted for the account at all. (The episode reset this requirement also calls for
    /// lives one layer up, in `MigrationManagerImpl.overrideBroadcastEndpointToSyncServer` — this
    /// storage type has no knowledge of `MigrationFailureRoutingStorage`.)
    func overrideBroadcastEndpointToSyncServerOnActiveSnapshot(for accountUUID: AccountUUID) {
        storage.modify(for: accountUUID) { payload in
            guard let existing = payload else {
                LoggerProxy.warn("[MigrationSnapshotStorage] overrideBroadcastEndpointToSyncServer: no active snapshot to update — ignoring.")
                return
            }
            payload = MigrationNetworkSnapshot(
                useTor: existing.useTor,
                syncEndpoint: existing.syncEndpoint,
                broadcastEndpoint: existing.syncEndpoint,
                takenAt: existing.takenAt,
                committedAt: existing.committedAt
            )
        }
    }
}

// MARK: - Persistence: broadcast-failure routing state (MOB-1497, R7-T3)

/// Per-account `UserDefaults`-backed persistence for `MigrationManagerImpl.routeBroadcastFailure`'s
/// three pieces of state: the had-broadcast flag (R14 first-run vs R15 mid-run), the broadcast-
/// endpoint "episode" (R16's per-account set of hosts already tried since the last landed
/// broadcast), and the Tor-hold indicator (R7 final review, Important-1 / spec §G — whether the
/// account's MOST RECENT routing outcome was `.torHold`, read by the waiting/stalled surfaces).
/// Same house pattern as `MigrationSnapshotStorage` beside which this lives: `final class`,
/// `@unchecked Sendable` guarded by an `OSAllocatedUnfairLock` around each read-modify-write,
/// injectable `UserDefaults` (default `.standard`) so tests can use an isolated named suite, same
/// per-account key suffix idiom.
final class MigrationFailureRoutingStorage: @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let lock = OSAllocatedUnfairLock(initialState: false)

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: Had-broadcast flag (R14/R15)

    /// First-run (this run has never had a landed broadcast) ⟺ `false`.
    func hadBroadcast(for accountUUID: AccountUUID) -> Bool {
        lock.withLock { _ in userDefaults.bool(forKey: hadBroadcastKey(for: accountUUID)) }
    }

    // MARK: Pending background-Tor-prompt latch (MOB-1497 T5, completed by E2E harness F#9)

    /// TRUE ⟺ a broadcast attempt routed `.torFirstRunChoice` (R14) and no surface has resolved
    /// the choice yet. The set/read half of the latch whose CLEARS (landed broadcast, run-end trio)
    /// shipped with MOB-1497 T5 — F#9 (2026-08-04) found the setter and reader were never wired, so
    /// a scheduled-lane user whose Tor was unreachable saw plain "in progress" forever with no path
    /// to the designed choice.
    func pendingTorPrompt(for accountUUID: AccountUUID) -> Bool {
        lock.withLock { _ in userDefaults.bool(forKey: pendingTorPromptKey(for: accountUUID)) }
    }

    /// Set/cleared at `routeBroadcastFailure`'s chokepoint — TRUE exactly when the route about to
    /// be returned is `.torFirstRunChoice`; any other verdict from a fresh attempt supersedes a
    /// stale pending prompt (an endpoint-class failure means the connection ran, so Tor is not the
    /// blocker any more). Also cleared by `MigrationManagerImpl.resolveTorPrompt` (choice consumed),
    /// `markHadBroadcast`, and `clear` (both pre-existing).
    func setPendingTorPrompt(_ pending: Bool, for accountUUID: AccountUUID) {
        lock.withLock { _ in
            if pending {
                userDefaults.set(true, forKey: pendingTorPromptKey(for: accountUUID))
            } else {
                userDefaults.removeObject(forKey: pendingTorPromptKey(for: accountUUID))
            }
        }
    }

    /// SET on any LANDED broadcast, on every lane (FG send, note split, BG — see
    /// `MigrationManagerImpl.recordTransferBroadcast`, the single call site). Also resets the R16
    /// episode: a fresh episode starts with every new transfer attempt window.
    ///
    /// R7 final review, Important-1: also clears the Tor-hold indicator — a landed broadcast is the
    /// freshest possible signal that Tor (if on) is reachable right now, so any previously-persisted
    /// hold no longer describes reality. MOB-1497 (T5): for the same reason, also clears the pending
    /// background-Tor-prompt latch — a landed broadcast means Tor is reachable, so any pending prompt
    /// from an earlier BG Tor failure this run is stale. Same lock acquisition as the clears above (one
    /// read-modify-write, not several).
    func markHadBroadcast(for accountUUID: AccountUUID) {
        lock.withLock { _ in
            userDefaults.set(true, forKey: hadBroadcastKey(for: accountUUID))
            userDefaults.removeObject(forKey: episodeKey(for: accountUUID))
            userDefaults.removeObject(forKey: torHoldKey(for: accountUUID))
            userDefaults.removeObject(forKey: pendingTorPromptKey(for: accountUUID))
        }
    }

    /// CLEARED at the run-end trio (`MigrationManagerImpl.acknowledgeComplete`/`resetPersistedFlags`/
    /// `reconcile`'s stale-`.notStarted` observation), beside the existing schedule/snapshot clears.
    /// Clears the flag, the episode, the Tor-hold indicator, and — MOB-1497 (T5) — the pending
    /// background-Tor-prompt latch (the run ending is the definitive resolution of any pending prompt
    /// tied to it).
    func clear(for accountUUID: AccountUUID) {
        lock.withLock { _ in
            userDefaults.removeObject(forKey: hadBroadcastKey(for: accountUUID))
            userDefaults.removeObject(forKey: episodeKey(for: accountUUID))
            userDefaults.removeObject(forKey: torHoldKey(for: accountUUID))
            userDefaults.removeObject(forKey: pendingTorPromptKey(for: accountUUID))
        }
    }

    // MARK: Episode set (R16)

    /// Read-only peek at the hosts tried this episode — never creates/mutates. Primarily for tests;
    /// `routeBroadcastFailure` itself uses `addEpisodeHost(_:for:)`'s return value instead, so the
    /// add-then-compute-candidates sequence reads one consistent snapshot of the set rather than two
    /// separately-locked calls that could interleave with a concurrent caller for the same account.
    func episodeHosts(for accountUUID: AccountUUID) -> [String] {
        lock.withLock { _ in readEpisodeHosts(for: accountUUID) }
    }

    /// Adds `host` to `accountUUID`'s episode set (a no-op if already present) and returns the
    /// resulting FULL set, in one locked read-modify-write.
    @discardableResult
    func addEpisodeHost(_ host: String, for accountUUID: AccountUUID) -> [String] {
        lock.withLock { _ in
            var hosts = readEpisodeHosts(for: accountUUID)
            guard !hosts.contains(host) else { return hosts }
            hosts.append(host)
            userDefaults.set(hosts, forKey: episodeKey(for: accountUUID))
            return hosts
        }
    }

    /// RESET on: a landed broadcast (see `markHadBroadcast`), the R17 sync-server override
    /// (`MigrationManagerImpl.overrideBroadcastEndpointToSyncServer`), and the run-end trio (see
    /// `clear`). Episode ONLY — deliberately does not touch the Tor-hold indicator below (same
    /// "never the flag" scoping this method already applies to `hadBroadcast`); by the time the R17
    /// override runs, `routeBroadcastFailure` has already cleared the indicator itself
    /// (`.providerExhausted` is one of the routes that clears it).
    func resetEpisode(for accountUUID: AccountUUID) {
        lock.withLock { _ in userDefaults.removeObject(forKey: episodeKey(for: accountUUID)) }
    }

    private func readEpisodeHosts(for accountUUID: AccountUUID) -> [String] {
        userDefaults.stringArray(forKey: episodeKey(for: accountUUID)) ?? []
    }

    // MARK: Tor-hold indicator (R7 final review, Important-1 / spec §G)

    /// Per-account: true iff the MOST RECENT `routeBroadcastFailure` outcome for this account was
    /// `.torHold` (R15 — a mid-run Tor outage) — i.e. the run is currently stalled specifically
    /// because Tor can't be reached, as opposed to any other reason. Read by the waiting/stalled
    /// surfaces (`MigrationStatusStore`'s resume presentation, `SmartBanner`'s transfer-waiting
    /// variant via `MigrationManagerImpl.bannerVariant`) to show a Tor-specific line — spec §G:
    /// "existing waiting/stalled surfaces gain a Tor-specific line." Defaults `false` (no known
    /// hold).
    func torHoldActive(for accountUUID: AccountUUID) -> Bool {
        lock.withLock { _ in userDefaults.bool(forKey: torHoldKey(for: accountUUID)) }
    }

    /// SET by `MigrationManagerImpl.routeBroadcastFailure`'s single chokepoint on EVERY call —
    /// `true` only when it is about to return `.torHold`, `false` for every other route (INCLUDING
    /// `.torFirstRunChoice`: a first-run Tor failure is a foreground CHOICE point, not a silent
    /// hold). Reflects the LAST known failure cause, not a sticky/latched flag — a later non-hold
    /// route (e.g. a rotation succeeding) clears it even before any broadcast lands. Both lanes hit
    /// this automatically since FG and BG call the same routing member — the BG lane needs no UI of
    /// its own; the indicator persisting here is the whole point. ALSO cleared by `markHadBroadcast`
    /// (a landed broadcast) and `clear` (the run-end trio) — see their docs.
    func setTorHoldActive(_ active: Bool, for accountUUID: AccountUUID) {
        lock.withLock { _ in userDefaults.set(active, forKey: torHoldKey(for: accountUUID)) }
    }

    // (Audit 2026-08-03, #16: the MOB-1497 T5 "pending background Tor prompt" latch's storage
    // was DELETED alongside its client members — nothing could arm it (its named arm site never
    // existed) and nothing could show it (its sheet is never presented). `markHadBroadcast`/
    // `clear` below still remove any value an older build may have persisted under its key.)

    // MARK: Keys

    private func hadBroadcastKey(for accountUUID: AccountUUID) -> String {
        "\(String.migrationHadBroadcast)_\(Data(accountUUID.id).hexEncodedString())"
    }

    private func episodeKey(for accountUUID: AccountUUID) -> String {
        "\(String.migrationBroadcastEpisode)_\(Data(accountUUID.id).hexEncodedString())"
    }

    private func torHoldKey(for accountUUID: AccountUUID) -> String {
        "\(String.migrationTorHold)_\(Data(accountUUID.id).hexEncodedString())"
    }

    private func pendingTorPromptKey(for accountUUID: AccountUUID) -> String {
        "\(String.migrationPendingTorPrompt)_\(Data(accountUUID.id).hexEncodedString())"
    }
}
