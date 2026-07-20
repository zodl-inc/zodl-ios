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
//  MOB-1496: `bannerVariant`/`reentryRoute`/`sendGate`/`reconcile` now read the real per-account,
//  throwing SDK surface — every SDK read degrades to a safe default (false/nil/entry) on either a
//  missing selected account or a thrown error, so a migration-surface hiccup never crashes launch,
//  foreground entry, or the smart banner. `migrationSummary`/`migrationTransfers`/`lockMigrationDust`/
//  `isMigrationDustLocked`/`stateEvents` are new here — relocated from `SDKSynchronizerClient`
//  (summary/transfers/dust-lock are app-side derivations/persistence, not SDK calls; stateEvents is
//  the per-account replacement for the old wallet-wide `migrationStateStream`).
//
//  MOB-1496 (W3): the privacy gate is now split across the SDK and this client. The SDK owns
//  broadcast->sync (`SDKSynchronizerClient.isMigrationSyncBlocked`/`migrationSyncBlockedStream`,
//  driven from `RootInitialization.swift`'s `.retryStart`/`.migrationSyncGateChanged`) — this
//  client's stub-era duplicate of that direction (`recordMigrationBroadcast`/
//  `isSyncDeferredAfterBroadcast`, keyed off `migrationLastBroadcastAt`) is retired. This client
//  keeps owning the OTHER direction — sync->send — re-keyed off observed sync completions
//  (`recordSyncCompleted`, `migrationLastSyncCompletedAt`) and the SDK's own
//  `migrationPrivacySyncBufferDuration()`, since the SDK only rejects a broadcast *during* an
//  active sync (advisory, point-in-time) rather than enforcing a post-sync cooldown itself.
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

import Foundation
@preconcurrency import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import os

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
            lockMigrationDust: { try await impl.lockMigrationDust() },
            isMigrationDustLocked: { impl.isMigrationDustLocked() },
            stateEvents: { accountUUID in impl.stateEvents(accountUUID: accountUUID) },
            migrationMode: { impl.gateStorage.migrationMode() },
            setMigrationMode: { impl.gateStorage.setMigrationMode($0) },
            isManualDelivery: { impl.gateStorage.isManualDelivery() },
            setManualDelivery: { impl.gateStorage.setManualDelivery($0) },
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
            overrideTorForRun: { accountUUID, useTor in
                impl.overrideTorForRun(accountUUID: accountUUID, useTor: useTor)
            },
            overrideBroadcastEndpointToSyncServer: { accountUUID in
                await impl.overrideBroadcastEndpointToSyncServer(accountUUID: accountUUID)
            },
            setNetworkPrivacyOptions: { impl.setNetworkPrivacyOptions(useTor: $0) },
            isCompleteAcknowledged: { accountUUID in impl.isCompleteAcknowledged(accountUUID: accountUUID) },
            acknowledgeComplete: { accountUUID in await impl.acknowledgeComplete(accountUUID: accountUUID) },
            isMigrationRemainderPending: { accountUUID in impl.isMigrationRemainderPending(accountUUID: accountUUID) },
            sendGate: { await impl.sendGate() },
            recordSyncCompleted: { impl.recordSyncCompleted() },
            migrationSyncGateFeed: { impl.migrationSyncGateFeed() },
            refreshMigrationSyncGate: { await impl.refreshMigrationSyncGate() },
            reconcile: { await impl.reconcile() },
            clearAbandonedNetworkSnapshot: { accountUUID in await impl.clearAbandonedNetworkSnapshot(accountUUID: accountUUID) },
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
/// `@Dependency(\.transactionGuard)`: nesting that guard here would risk exactly the deadlock its
/// own doc warns against (non-reentrant, and `MigrationManagerImpl.ensureNetworkSnapshot` already
/// acquires it elsewhere in this same class), and it would be serializing a disjoint set of
/// operations anyway (submission-vs-switch exclusivity, not this class's storage-mutating passes).
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

/// Composes `sdkSynchronizer` + `MigrationGateStorage` and owns the per-account `stateEvents`
/// subjects. `@unchecked Sendable`: the only mutable state is `gateStorage`'s own
/// `OSAllocatedUnfairLock`-protected storage, the `serialExecutor` actor, plus the Combine subjects
/// below, all of which are safe to share across isolation domains.
final class MigrationManagerImpl: @unchecked Sendable {
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
    @Dependency(\.transactionGuard) var transactionGuard
    // MOB-1497 (R7): the uniform-random broadcast-endpoint pick's test-controllable randomness seam
    // — see `MigrationRandomnessInterface.swift`'s doc for why this exists instead of a raw
    // `RandomNumberGenerator`.
    @Dependency(\.migrationRandomness) var migrationRandomness

    @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
    @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []

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

    /// Internal (not private) with injectable storage so unit tests can exercise the real
    /// `reconcile()` against a scoped `UserDefaults` suite.
    init(
        gateStorage: MigrationGateStorage = MigrationGateStorage(),
        scheduleStorage: MigrationScheduleStorage = MigrationScheduleStorage(),
        snapshotStorage: MigrationSnapshotStorage = MigrationSnapshotStorage(),
        failureRoutingStorage: MigrationFailureRoutingStorage = MigrationFailureRoutingStorage()
    ) {
        self.gateStorage = gateStorage
        self.scheduleStorage = scheduleStorage
        self.snapshotStorage = snapshotStorage
        self.failureRoutingStorage = failureRoutingStorage
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

    /// R8-T3 (#23): every underlying SDK/storage read below happens exactly ONCE — the pre-fix
    /// version read `state` via `normalizedState`'s own `migrationState` call and AGAIN inside
    /// `migrationTransfers`'s has-schedule branch, `hasOverdue` inside `migrationTransfers` and
    /// AGAIN directly here, `progress` inside `isNextTransferDue` (and, on the W1-fallback path,
    /// inside `migrationTransfers` too) — PLUS an unused `hasInvalidMigrationTransfers` read whose
    /// result fed a `MigrationDerivations.bannerVariant` parameter the function's body never
    /// actually consulted (the `.invalidTransfer` case is decided purely from `state`'s own
    /// pattern-match) — deleted below along with the read, rather than kept for a value nothing
    /// uses.
    func bannerVariant(accountUUID: AccountUUID?) async -> MigrationBannerVariant? {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return nil }
        guard let rawState = await migrationState(accountUUID: resolvedAccountUUID) else { return nil }

        async let progressTask = migrationProgress(accountUUID: resolvedAccountUUID)
        async let hasOverdueTask = hasOverdueMigrationTransfers(accountUUID: resolvedAccountUUID)
        async let balanceTask = orchardBalanceToMigrate(accountUUID: resolvedAccountUUID)

        let progress = await progressTask
        let hasOverdue = await hasOverdueTask
        let balance = await balanceTask

        let state = normalizedState(rawState: rawState, progress: progress)
        let rows = bannerTransferRows(resolvedAccountUUID: resolvedAccountUUID, state: state, hasOverdue: hasOverdue, progress: progress)

        return MigrationDerivations.bannerVariant(
            isIronwoodActivated: isIronwoodActivated(),
            state: state,
            hasOverdue: hasOverdue,
            isManualDelivery: gateStorage.isManualDelivery(),
            isNextTransferDue: isNextTransferDue(progress: progress),
            orchardBalance: balance,
            isCompleteAcknowledged: gateStorage.isCompleteAcknowledged(for: resolvedAccountUUID),
            // MOB-1496: nil (never evaluated) reads as `false` here, same "not known to be
            // pending" convention `MigrationManagerImpl.isMigrationRemainderPending` uses.
            isMigrationRemainderPending: gateStorage.remainderPending(for: resolvedAccountUUID) ?? false,
            transferRows: rows,
            // R7 final review, Important-1 (spec §G): threads the persisted Tor-hold indicator into
            // `.transferWaiting`'s `torHold` flag — see `MigrationFailureRoutingStorage
            // .torHoldActive`'s doc.
            isTorHoldActive: failureRoutingStorage.torHoldActive(for: resolvedAccountUUID)
        )
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
    /// read `progress` up to 3x (once inside `normalizedState`'s conditional branch, once directly
    /// here, once again inside `isNextTransferDue`). Unlike `bannerVariant`'s `hasInvalid`,
    /// `reentryRoute`'s OWN `hasInvalid` read stays: `MigrationDerivations.reentryRoute` genuinely
    /// branches on it (row 1, `.recovery`).
    func reentryRoute() async -> MigrationReentryRoute {
        guard let accountUUID = selectedWalletAccount?.id else { return MigrationReentryRoute.entry }

        async let rawStateTask = migrationState(accountUUID: accountUUID)
        async let progressTask = migrationProgress(accountUUID: accountUUID)
        async let hasInvalidTask = hasInvalidMigrationTransfers(accountUUID: accountUUID)
        async let hasOverdueTask = hasOverdueMigrationTransfers(accountUUID: accountUUID)

        let rawState = await rawStateTask ?? MigrationState.notStarted
        let progress = await progressTask
        let hasInvalid = await hasInvalidTask
        let hasOverdue = await hasOverdueTask

        let state = normalizedState(rawState: rawState, progress: progress)

        return MigrationDerivations.reentryRoute(
            isIronwoodActivated: isIronwoodActivated(),
            state: state,
            hasInvalid: hasInvalid,
            hasOverdue: hasOverdue,
            isManualDelivery: gateStorage.isManualDelivery(),
            isNextTransferDue: isNextTransferDue(progress: progress),
            isCompleteAcknowledged: gateStorage.isCompleteAcknowledged(for: accountUUID),
            progress: progress
        )
    }

    func orchardBalanceToMigrate(accountUUID: AccountUUID?) async -> Zatoshi {
        // MOB-1480: simulator active -> its own balance replaces the real per-account SDK read
        // (the simulated migration has no real funds to look up against `accountUUID`).
        if MigrationSimulatorFlag.isEnabled && MigrationSimulatorClient.sharedEngine.isActive {
            return MigrationSimulatorClient.sharedEngine.orchardBalance()
        }

        guard let accountUUID else { return .zero }

        guard let balances = try? await sdkSynchronizer.getAccountsBalances(),
              let balance = balances[accountUUID] else {
            return .zero
        }

        return balance.orchardBalance.total()
    }

    /// MOB-1496 W2: derives from the persisted committed schedule (`MigrationScheduleStorage`) +
    /// live reads, via `MigrationDerivations.summary`. No payload persisted (fresh install mid-run,
    /// or pre-commit — the SDK retains no proposal list to derive from either) falls back to the W1
    /// progress-only approximation, kept verbatim below rather than deleted.
    ///
    /// Simulator reach-around: the simulator engine's own purpose-built `summary()` (real
    /// sent/pending amounts, durations, etc. — the whole point of the simulator's demo data) is far
    /// richer than anything derivable through the real SDK members while the simulator is standing
    /// in for it — reading through them anyway would silently downgrade every simulated QA session.
    /// Gated exactly like `orchardBalanceToMigrate`'s existing reach-around.
    func migrationSummary(accountUUID: AccountUUID?) async -> MigrationSummary {
        if MigrationSimulatorFlag.isEnabled && MigrationSimulatorClient.sharedEngine.isActive {
            return MigrationSimulatorClient.sharedEngine.summary()
        }

        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return MigrationSummary.zero }

        guard let committedSchedule = scheduleStorage.committedSchedule(for: resolvedAccountUUID) else {
            // [MOB-1496] W1 fallback: no persisted payload yet — everything derivable comes from
            // `getMigrationProgress` alone (counts and the remaining Orchard value, mapped onto
            // `dust`). `transferred`/`estimatedDurationHours` need per-transfer amounts and the
            // schedule's own duration estimate, neither recoverable from progress alone, so they
            // stay `0`. On a missing account or any SDK-read error, `.zero`.
            guard let progress = await migrationProgress(accountUUID: resolvedAccountUUID) else { return MigrationSummary.zero }

            return MigrationSummary(
                transferred: Zatoshi.zero,
                dust: progress.remainingOrchard,
                transfersSent: progress.completedTransfers,
                transfersTotal: progress.totalTransfers,
                estimatedDurationHours: 0
            )
        }

        let state = await migrationState(accountUUID: resolvedAccountUUID) ?? MigrationState.notStarted
        // Flattens `Zatoshi??` (threw, or genuinely no residual) down to `nil` either way — both
        // read as "not available" per the derivation's own fallback precedence.
        let residual = (try? await sdkSynchronizer.residualAfterMigration(resolvedAccountUUID)) ?? nil
        let progress = await migrationProgress(accountUUID: resolvedAccountUUID)

        return MigrationDerivations.summary(
            committedSchedule: committedSchedule,
            state: state,
            residual: residual,
            progress: progress
        )
    }

    /// MOB-1496 W2: derives from the persisted committed schedule + live reads (`getMigrationState`,
    /// `hasOverdueMigrationTransfers`), via `MigrationDerivations.transferRows`. No payload
    /// persisted falls back to the W1 progress-only approximation, kept verbatim below.
    ///
    /// Simulator reach-around — see `migrationSummary`'s doc: the engine's own `transferRows()`
    /// carries real per-row status (sent/active/overdue/invalid/expired, broadcasting, precise
    /// recency) the persisted-schedule derivation intentionally doesn't reproduce (no broadcasting
    /// flag, no sub-hour simulated cadence).
    func migrationTransfers(accountUUID: AccountUUID?) async -> [MigrationTransferRow] {
        if MigrationSimulatorFlag.isEnabled && MigrationSimulatorClient.sharedEngine.isActive {
            return MigrationSimulatorClient.sharedEngine.transferRows()
        }

        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return [] }

        guard let committedSchedule = scheduleStorage.committedSchedule(for: resolvedAccountUUID) else {
            // [MOB-1496] W1 fallback — see `synthesizedTransferRows`'s doc for the exact rules. On a
            // missing account or any SDK-read error, `[]`.
            guard let progress = await migrationProgress(accountUUID: resolvedAccountUUID) else { return [] }
            return Self.synthesizedTransferRows(progress: progress)
        }

        let state = await migrationState(accountUUID: resolvedAccountUUID) ?? MigrationState.notStarted
        let hasOverdue = await hasOverdueMigrationTransfers(accountUUID: resolvedAccountUUID)

        return MigrationDerivations.transferRows(
            committedSchedule: committedSchedule,
            state: state,
            hasOverdueMigrationTransfers: hasOverdue,
            now: Date()
        )
    }

    /// [MOB-1496] W1 fallback: no persisted payload yet — rows are synthesized purely from
    /// `getMigrationProgress`'s counts: index < completedTransfers reads `.sent`, everything else
    /// `.pending` (no `.active`/`.overdue`/`.invalid`/`.expired` — those need per-transfer identity a
    /// persisted schedule would carry); `hoursFromNow` is a rough `(index - completed) × 6h` cadence
    /// estimate, clamped ≥ 0. `amount`/`id` are placeholders. Shared by the public
    /// `migrationTransfers(accountUUID:)` and `bannerVariant`'s own row derivation (R8-T3 #23),
    /// which otherwise would have re-derived this independently after already fetching `progress`.
    private static func synthesizedTransferRows(progress: MigrationProgress) -> [MigrationTransferRow] {
        (0..<progress.totalTransfers).map { index in
            MigrationTransferRow(
                id: "\(index)",
                index: index,
                amount: Zatoshi.zero,
                status: index < progress.completedTransfers ? MigrationTransferRow.Status.sent : MigrationTransferRow.Status.pending,
                hoursFromNow: max(0, (index - progress.completedTransfers) * 6)
            )
        }
    }

    /// R8-T3 (#23): `bannerVariant`'s own row derivation — mirrors `migrationTransfers(accountUUID:)`'s
    /// branching logic exactly, but takes `state`/`hasOverdue`/`progress` already fetched by the
    /// caller instead of re-reading them (this file's public `migrationTransfers` keeps its own
    /// independent reads unchanged; only the tiny W1-fallback synthesis is shared, via
    /// `synthesizedTransferRows`, to avoid coupling the two methods' read patterns together).
    private func bannerTransferRows(
        resolvedAccountUUID: AccountUUID,
        state: MigrationState,
        hasOverdue: Bool,
        progress: MigrationProgress?
    ) -> [MigrationTransferRow] {
        if MigrationSimulatorFlag.isEnabled && MigrationSimulatorClient.sharedEngine.isActive {
            return MigrationSimulatorClient.sharedEngine.transferRows()
        }

        guard let committedSchedule = scheduleStorage.committedSchedule(for: resolvedAccountUUID) else {
            guard let progress else { return [] }
            return Self.synthesizedTransferRows(progress: progress)
        }

        return MigrationDerivations.transferRows(
            committedSchedule: committedSchedule,
            state: state,
            hasOverdueMigrationTransfers: hasOverdue,
            now: Date()
        )
    }

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
    /// deferred store success in `MigrationCoordFlowCoordinator.storeDeferredKeystoneSchedule`, the
    /// Keystone no-split immediate store, and the software dust commit) so the schedule commit and
    /// the snapshot commit can never drift out of sync. Ordered after the schedule write: a snapshot
    /// briefly still reading provisional while the schedule is already durable is harmless (nothing
    /// reads `committedAt` in that narrow window), whereas the reverse order risks a snapshot that
    /// reads committed for a schedule write that then fails. The stamp rides INSIDE the same
    /// serialized critical section as the schedule write (rebase of MOB-1497 onto R8-T3): it is a
    /// mutating pass over the same per-run storage pair the executor exists to serialize.
    func recordCommittedSchedule(accountUUID: AccountUUID?, schedule: MigrationSchedule) async {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
        await serialExecutor.run { [self] in
            scheduleStorage.recordCommittedSchedule(schedule, for: resolvedAccountUUID, now: Date())
            markNetworkSnapshotCommitted(accountUUID: resolvedAccountUUID)
        }
    }

    /// MOB-1496 (W2): records a successful transfer broadcast against the persisted schedule
    /// (appends a `SentRecord` for the first not-yet-sent transfer, in schedule order); non-success
    /// results and a missing payload (nothing to append against) are both no-ops — see
    /// `MigrationScheduleStorage.recordTransferBroadcast`.
    ///
    /// MOB-1497 (R7-T3): this is the manager-layer chokepoint every LANDED-broadcast lane funnels
    /// through — FG send (`MigrationSendingStore`, including the dust lane), FG note split
    /// (`MigrationNoteSplitStore`, both the software and Keystone forks), and BG
    /// (`RootInitialization.handleLandedBroadcast`) — so a `.success` here also marks the had-
    /// broadcast flag (R14 first-run vs R15 mid-run) and resets the R16 episode set (a fresh episode
    /// starts with every new transfer attempt window). A note split's own broadcast is not one of
    /// `scheduleStorage`'s schedule transfers, but the guard inside `MigrationScheduleStorage
    /// .recordTransferBroadcast` (no payload yet -> no-op) makes calling it from that lane harmless
    /// today: every live note-split broadcast happens BEFORE `recordCommittedSchedule` persists this
    /// run's schedule (see `MigrationNoteSplitStore`'s header doc) — flagged in the T3 report as a
    /// timing-dependent assumption worth a comment here rather than a silent one.
    func recordTransferBroadcast(accountUUID: AccountUUID?, result: MigrationTransferResult) async {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
        if case MigrationTransferResult.success = result {
            failureRoutingStorage.markHadBroadcast(for: resolvedAccountUUID)
        }
        scheduleStorage.recordTransferBroadcast(result, for: resolvedAccountUUID, now: Date())
    }

    /// MOB-1487/MOB-1496: no SDK primitive — "Lock balance" is app-only bookkeeping (marks the
    /// identified Orchard remainder unspendable instead of migrating it). The short pause keeps the
    /// "Locking balance" in-flight state observable, matching the pre-relocation
    /// `SDKSynchronizerClient` stub. Simulator reach-around mirrors the engine's own (shorter)
    /// simulated latency, matching its pre-relocation wiring in `SDKSynchronizerClient+Simulated`.
    func lockMigrationDust() async throws {
        if MigrationSimulatorFlag.isEnabled && MigrationSimulatorClient.sharedEngine.isActive {
            try await Task.sleep(for: .seconds(0.5))
            MigrationSimulatorClient.sharedEngine.lockDust()
            return
        }

        try await Task.sleep(nanoseconds: 800_000_000)
        gateStorage.setDustLocked(true)
    }

    func isMigrationDustLocked() -> Bool {
        if MigrationSimulatorFlag.isEnabled && MigrationSimulatorClient.sharedEngine.isActive {
            return MigrationSimulatorClient.sharedEngine.isDustLocked()
        }
        return gateStorage.isDustLocked()
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
    /// DO-NOT-NEST WARNING: internally serializes creation against a mid-flight server switch via
    /// `transactionGuard.withSubmission` — `TransactionGuard` is NON-REENTRANT (a nested
    /// `withSubmission`/`switchIfIdle`/`switchWaiting` deadlocks: the inner `acquire()` waits forever
    /// for a `release()` that can only happen after the inner call itself returns). NEVER call this
    /// from inside another `withSubmission`/`switchIfIdle`/`switchWaiting` block — in particular,
    /// never from inside `SDKSynchronizerLive`'s own guarded closures. Every call site in this
    /// codebase reads options in the store/effect BEFORE invoking the broadcast client member (which
    /// takes the guard internally in ITS OWN LiveKey), never from after/inside it.
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
    /// Keystone note-split lane broadcasts BEFORE its schedule (and therefore its snapshot) commits,
    /// by design: `MigrationCoordFlowCoordinator.storeDeferredKeystoneSchedule` defers
    /// `recordCommittedSchedule`/`markNetworkSnapshotCommitted` until AFTER the split's OWN broadcast
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
    /// `formNetworkSnapshot`'s doc for why that's always safe pre-broadcast). Double-checks presence
    /// (and the same committed/reform condition) again AFTER acquiring the guard, not just before — a
    /// concurrent first caller for the SAME account may have already created/persisted or reformed
    /// one while this call waited, and that one must win rather than being silently overwritten. A
    /// missing/unresolvable account still returns SOME snapshot (the current endpoint/Tor choice,
    /// unpersisted) — every path ends in a value, never a throw.
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

        // DO-NOT-NEST: see `migrationNetworkOptions`'s doc — this must never run inside another
        // `withSubmission`/`switchIfIdle`/`switchWaiting`.
        let guarded = try? await transactionGuard.withSubmission { () async -> MigrationNetworkSnapshot in
            if let resolvedAccountUUID,
               let existing = snapshotStorage.snapshot(for: resolvedAccountUUID),
               existing.committedAt != nil || !reformIfProvisional {
                return existing
            }
            var created = await createNetworkSnapshot()
            if stampCommitted {
                created.committedAt = Date()
            }
            if let resolvedAccountUUID {
                snapshotStorage.recordSnapshot(created, for: resolvedAccountUUID)
            }
            return created
        }

        // `withSubmission` only throws on task cancellation (`acquire()`'s `CancellationError`) — the
        // closure body above never throws. Even a cancelled guard acquisition must still end in SOME
        // snapshot (never a throw) — fall back to an unguarded, unpersisted read.
        if let guarded {
            return guarded
        }
        var fallback = await createNetworkSnapshot()
        if stampCommitted {
            fallback.committedAt = Date()
        }
        return fallback
    }

    /// The actual read+random-pick sequence for a fresh snapshot — see
    /// `ensureOrCreateNetworkSnapshot`'s doc for the guard this always runs inside. Never throws;
    /// every path ends in a snapshot, always freshly PROVISIONAL (`committedAt == nil` — the caller
    /// stamps it when `stampCommitted` is set). MOB-1497 (R7): makes ZERO network calls — no
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

    /// MOB-1496 (W3): blocked when EITHER (a) the synchronizer is actively syncing right now, or
    /// (b) a sync completed less than `migrationPrivacySyncBufferDuration()` ago. (a) is checked
    /// first — an active sync is the more specific/urgent state of the two, and mirrors the old
    /// stub's own precedence (sync-required-outright before the timing window).
    func sendGate() async -> MigrationSendGate {
        if sdkSynchronizer.isSyncing() {
            return MigrationSendGate.syncRequired
        }

        let buffer = sdkSynchronizer.migrationPrivacySyncBufferDuration()
        return gateStorage.sendGate(now: Date(), buffer: buffer)
    }

    /// MOB-1496 (W3): called from Root's sync-completion edge (`RootInitialization.swift`'s
    /// `.synchronizerStateChanged`, the false->true transition into `.upToDate` — the same edge
    /// `reconcile()` fires on) so this updates once per completed sync, never per tick.
    func recordSyncCompleted() {
        gateStorage.recordSyncCompleted(at: Date())
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
        }
    }

    /// MOB-1496 (R8-T4, #3): read+yield only — see `MigrationManagerClient.refreshMigrationSyncGate`'s
    /// doc. Deliberately outside `serialExecutor` (mutates none of this class's own persisted state —
    /// the continuation box is throwaway plumbing, not app state) and never touches `transactionGuard`
    /// (not a broadcast/server-switch).
    func refreshMigrationSyncGate() async {
        let isBlocked = await sdkSynchronizer.isMigrationSyncBlocked()
        migrationSyncGateContinuation.withLock { $0?.yield(isBlocked) }
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
                    await evaluateMigrationRemainder(for: accountUUID)
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
    /// that just reached `.complete` — a fresh, non-committing `proposeMigrationTransfers(_, false)`;
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
    private func evaluateMigrationRemainder(for accountUUID: AccountUUID) async {
        guard let schedule = try? await sdkSynchronizer.proposeMigrationTransfers(accountUUID, false) else { return }
        gateStorage.setRemainderPending(!schedule.transfers.isEmpty, for: accountUUID)
    }

    /// R8-T3 (#24): per-account lookup against `reconcile()`'s ONE hoisted `getAccountsBalances()`
    /// read — mirrors `orchardBalanceToMigrate`'s own derivation (including the simulator
    /// reach-around) without re-issuing the full-wallet read itself.
    private func reconcileOrchardBalance(from walletBalances: [AccountUUID: AccountBalance]?, accountUUID: AccountUUID) -> Zatoshi {
        if MigrationSimulatorFlag.isEnabled && MigrationSimulatorClient.sharedEngine.isActive {
            return MigrationSimulatorClient.sharedEngine.orchardBalance()
        }
        guard let balance = walletBalances?[accountUUID] else { return .zero }
        return balance.orchardBalance.total()
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
    /// warning indefinitely. Called fire-and-forget from the coordinator's `.flowFinished` handler
    /// (every flow-root close / terminal delegate) for the selected account (`nil` resolves it,
    /// same convention as `migrationSummary`/`recordCommittedSchedule` above): reads `accountUUID`'s
    /// engine state FRESH — `.notStarted` with no stored schedule payload means nothing was ever
    /// committed this attempt (or the run genuinely finished/reset already) — clears its snapshot;
    /// any other state (a real active/committed run) is a no-op. R8-T3 (#18): serialized alongside
    /// `reconcile`/`recordCommittedSchedule`/`acknowledgeComplete` for the same TOCTOU reasons.
    /// Deliberately self-contained (doesn't reach for anything a real run's schedule/state would
    /// carry) so the R7 branch's provisional-snapshot machinery can subsume it on rebase.
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

    /// MOB-1480: the migration SDK simulator's debug panel "Reset app migration flags" control.
    /// MOB-1496 (W2): also clears every candidate account's persisted schedule — a debug reset must
    /// leave no stale committed-schedule payload behind either. MOB-1496 (W4): and its network
    /// snapshot; MOB-1497 (R7-T3): and its failure-routing state (had-broadcast flag + R16
    /// episode). R8-T3: sourced from `MigrationDerivations.candidateAccountUUIDs` (was two separate
    /// hand-rolled loops — `walletAccounts`, then `selectedWalletAccount` again, redundantly
    /// re-clearing it — that disagreed with `reconcile()`'s/`activeNetworkSnapshots()`'s own
    /// account-set logic); also now clears each candidate account's own per-account acknowledged
    /// flag (R8-T3 S2 — the flag itself used to be wallet-wide, cleared directly by
    /// `gateStorage.resetPersistedFlags()` alone). MOB-1496: also clears each candidate account's
    /// own per-account remainder verdict — same rationale as the acknowledged flag, since a debug
    /// reset must leave no stale "more to migrate" verdict behind either.
    func resetPersistedFlags() {
        gateStorage.resetPersistedFlags()
        let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: selectedWalletAccount?.id,
            walletAccounts: walletAccounts
        )
        for accountUUID in accountUUIDs {
            gateStorage.clearAcknowledgedComplete(for: accountUUID)
            gateStorage.clearRemainderPending(for: accountUUID)
            scheduleStorage.clear(for: accountUUID)
            snapshotStorage.clear(for: accountUUID)
            failureRoutingStorage.clear(for: accountUUID)
        }
    }

    /// `.requiresAttention(.syncRequiredBeforeNext)` carries no progress payload of its own, but
    /// per spec it renders identically to a plain `.inProgress(p)` banner — so it's normalized to
    /// that shape here from an already-fetched `rawState`/`progress` pair (R8-T3 #23: `bannerVariant`
    /// and `reentryRoute` both fetch these once themselves now, rather than this function doing its
    /// own redundant `migrationState`/`migrationProgress` reads). `rawState`'s own read failure is
    /// the caller's concern (each defaults it to `.notStarted`, or short-circuits first — see
    /// `bannerVariant`/`reentryRoute`). MOB-1496: `.syncRequiredBeforeNext` itself is never actually
    /// emitted by the final migration engine either — this normalization is kept purely for
    /// exhaustiveness (and the migration SDK simulator, which still models the reason) rather than
    /// any real-engine behavior it needs to cover.
    private func normalizedState(rawState: MigrationState, progress: MigrationProgress?) -> MigrationState {
        guard case MigrationState.requiresAttention(MigrationAttentionReason.syncRequiredBeforeNext) = rawState,
              let progress else {
            return rawState
        }
        return MigrationState.inProgress(progress)
    }

    /// "Next due" (manual): ready height already reached (or unknown / no progress -> not due).
    /// R8-T3 (#23): takes an already-fetched `progress` instead of reading it itself — `bannerVariant`/
    /// `reentryRoute` both already have one in hand by the time they need this.
    private func isNextTransferDue(progress: MigrationProgress?) -> Bool {
        // MOB-1480: `nextTransferReadyAtHeight` is a synthetic (epoch-seconds) height while the
        // simulator is active, which can never compare true against the real chain's
        // `latestBlockHeight` below — ask the engine directly instead (ignoring `progress`, which
        // would carry that same synthetic value).
        if MigrationSimulatorFlag.isEnabled && MigrationSimulatorClient.sharedEngine.isActive {
            return MigrationSimulatorClient.sharedEngine.isNextTransferDue()
        }

        guard let readyAtHeight = progress?.nextTransferReadyAtHeight else {
            return false
        }

        return readyAtHeight <= sdkSynchronizer.latestState().latestBlockHeight
    }

    /// MOB-1483: "Ironwood (NU6.3) activated on the current network." `tip > 0` is the fail-safe
    /// sentinel — a cached tip of `0` (before the first server round-trip) is an *unknown* tip, not
    /// a low one, so it must read as "not activated" rather than happening to satisfy `tip >=
    /// activationHeight` by coincidence (mirrors the sentinel idiom in
    /// `SDKSynchronizerClient.transactionStatesFromZcashTransactions`). Not `private`: wired
    /// directly to `MigrationManagerClient.isIronwoodActivated` in `live()`.
    func isIronwoodActivated() -> Bool {
        // An active simulator bypasses the real-chain gate (MOB-1483 spec §5, same idiom as the
        // simulator hooks above): a fresh-install/offline testnet run has tip == 0 and would
        // otherwise hide the simulated migration behind the fail-safe sentinel.
        if MigrationSimulatorFlag.isEnabled && MigrationSimulatorClient.sharedEngine.isActive {
            return true
        }
        let tip = sdkSynchronizer.latestState().latestBlockHeight
        return tip > 0 && tip >= zcashSDKEnvironment.ironwoodActivationHeight()
    }

    // MARK: - MOB-1496: throwing-SDK-read helpers (account-scoped, degrade on error)

    private func migrationState(accountUUID: AccountUUID) async -> MigrationState? {
        guard let result = try? await sdkSynchronizer.getMigrationState(accountUUID) else { return nil }
        return result
    }

    private func migrationProgress(accountUUID: AccountUUID) async -> MigrationProgress? {
        guard let result = try? await sdkSynchronizer.getMigrationProgress(accountUUID) else { return nil }
        return result
    }

    private func hasInvalidMigrationTransfers(accountUUID: AccountUUID) async -> Bool {
        (try? await sdkSynchronizer.hasInvalidMigrationTransfers(accountUUID)) ?? false
    }

    private func hasOverdueMigrationTransfers(accountUUID: AccountUUID) async -> Bool {
        (try? await sdkSynchronizer.hasOverdueMigrationTransfers(accountUUID)) ?? false
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
        let subject = subject(for: accountUUID)
        let previousHasBalance = lastPushedHasBalance.withLock { $0[accountUUID] ?? false }

        guard subject.value != state || previousHasBalance != hasBalanceToMigrate else { return }

        lastPushedHasBalance.withLock { $0[accountUUID] = hasBalanceToMigrate }
        subject.send(state)
    }
}

// MARK: - Pure derivations (table-testable, no SDK dependency)

/// Pure mappings from SDK-observed migration state (plus a handful of app-side flags) onto what
/// the UI shows. Every function here is a straight table lookup — no dates, no I/O, no SDK types
/// beyond the value models already `Equatable`/`Sendable` (`MigrationState`, `MigrationProgress`,
/// `MigrationAttentionReason`, `MigrationTransferRow`) — so `MigrationManagerTests` can exercise
/// every row directly.
enum MigrationDerivations {
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

    /// See MOB-1466 spec, "bannerVariant derivation" table. `isIronwoodActivated` (MOB-1483) is
    /// checked first and gates the whole derivation — pre-activation there is no banner.
    ///
    /// MOB-1496: the SDK's `MigrationAttentionReason` has no `.transferStalled` case (that was a
    /// pre-real-SDK invention) — "stalled" is now derived, not carried by the state itself: an
    /// `.inProgress` migration with `hasOverdue` true reads as `.transferWaiting`, checked BEFORE
    /// the manual-ready check (mirrors `reentryRoute`'s existing `hasOverdue`-before-
    /// `isManualDelivery && isNextTransferDue` precedence), transferNumber = `completedTransfers +
    /// 1`.
    ///
    /// R8-T3 (#23): dropped the `hasInvalid: Bool` parameter this function used to take — the
    /// `.invalidTransfer` case below is, and always was, decided purely by pattern-matching
    /// `state`'s own `.requiresAttention(.invalidTransfer)` case; the separate `hasInvalid` boolean
    /// input was never referenced in this body. Its only caller (`MigrationManagerImpl.bannerVariant`)
    /// no longer computes it either, removing a wasted `hasInvalidMigrationTransfers` SDK read per
    /// call. `reentryRoute` below keeps its OWN `hasInvalid` parameter — that one genuinely is
    /// consulted (row 1, `.recovery`).
    ///
    /// R7 final review, Important-1 (spec §G): `isTorHoldActive` carries into `.transferWaiting`'s
    /// `torHold` flag (see that case's own doc) — defaults `false` so every pre-existing call site
    /// (none of which know about the indicator) is unaffected.
    static func bannerVariant(
        isIronwoodActivated: Bool,
        state: MigrationState,
        hasOverdue: Bool,
        isManualDelivery: Bool,
        isNextTransferDue: Bool,
        orchardBalance: Zatoshi,
        isCompleteAcknowledged: Bool,
        isMigrationRemainderPending: Bool,
        transferRows: [MigrationTransferRow],
        isTorHoldActive: Bool = false
    ) -> MigrationBannerVariant? {
        guard isIronwoodActivated else { return nil }

        switch state {
        // `.readyToPropose` is never actually emitted by the final migration engine — kept here
        // only for exhaustiveness / the migration SDK simulator, which still models it.
        case MigrationState.notStarted, MigrationState.readyToPropose:
            return orchardBalance > Zatoshi.zero ? MigrationBannerVariant.required : nil

        case MigrationState.splitPendingConfirmation:
            return MigrationBannerVariant.splitting

        case let MigrationState.inProgress(progress):
            if hasOverdue {
                return MigrationBannerVariant.transferWaiting(number: progress.completedTransfers + 1, torHold: isTorHoldActive)
            }
            if isManualDelivery && isNextTransferDue {
                return MigrationBannerVariant.transferReady(number: progress.completedTransfers + 1)
            }
            return MigrationBannerVariant.inProgress(done: progress.completedTransfers, total: progress.totalTransfers)

        case let MigrationState.requiresAttention(reason):
            switch reason {
            case MigrationAttentionReason.invalidTransfer:
                return MigrationBannerVariant.updatePlan

            case MigrationAttentionReason.transferExpired:
                let (first, last) = expiredBounds(transferRows: transferRows)
                return MigrationBannerVariant.transfersExpired(first: first, last: last)

            case MigrationAttentionReason.syncRequiredBeforeNext:
                // Normalized to `.inProgress` by the LiveKey before this function is ever called
                // with this state — this branch only exists so the switch stays exhaustive. (Never
                // actually emitted by the final migration engine either — see `normalizedState`'s
                // doc — so in production this arm is unreachable, not merely pre-empted.)
                return nil
            }

        case MigrationState.complete:
            guard isCompleteAcknowledged else { return MigrationBannerVariant.complete }
            // MOB-1496: `.complete` is per-RUN now — the engine may still have more to migrate (a
            // per-run cap, or funds arriving mid-run). `isMigrationRemainderPending` reflects the
            // ONE fresh `proposeMigrationTransfers` this completion transition ever gets (see
            // `MigrationManagerImpl.evaluateMigrationRemainder`'s doc) — a non-empty plan re-offers
            // the banner as `.required`, exactly like a fresh pre-run balance would, with no
            // `orchardBalance` predicate needed (the engine already said there's something there).
            return isMigrationRemainderPending ? MigrationBannerVariant.required : nil
        }
    }

    /// See MOB-1466 spec, "reentryRoute" — §4.3 table, checked in this exact order.
    /// `isIronwoodActivated` (MOB-1483) is checked first, ahead of row 1 — pre-activation every
    /// input falls through to `.entry`.
    static func reentryRoute(
        isIronwoodActivated: Bool,
        state: MigrationState,
        hasInvalid: Bool,
        hasOverdue: Bool,
        isManualDelivery: Bool,
        isNextTransferDue: Bool,
        isCompleteAcknowledged: Bool,
        progress: MigrationProgress?
    ) -> MigrationReentryRoute {
        guard isIronwoodActivated else { return MigrationReentryRoute.entry }

        if hasInvalid {
            let isExpired = isTransferExpired(state)
            return MigrationReentryRoute.recovery(isExpired: isExpired)
        }

        if hasOverdue {
            return MigrationReentryRoute.statusResume
        }

        if isManualDelivery && isNextTransferDue, let progress {
            return MigrationReentryRoute.reviewManual(step: progress.completedTransfers + 1, total: progress.totalTransfers)
        }

        if case MigrationState.inProgress = state {
            return MigrationReentryRoute.statusProgress
        }

        if case MigrationState.complete = state {
            return isCompleteAcknowledged ? MigrationReentryRoute.entry : MigrationReentryRoute.complete
        }

        if case MigrationState.splitPendingConfirmation = state {
            return MigrationReentryRoute.noteSplitProgress
        }

        return MigrationReentryRoute.entry
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
    /// `hoursFromNow`: sent rows carry "hours ago" (floor) + `sentMinutesAgo` (sub-hour precision,
    /// matching `MigrationSimulatorEngineDerivations.captionFields`'s `.sent` case); non-sent rows
    /// keep W1's index-cadence estimate, now computed over the row's 0-based position AMONG
    /// non-sent rows (`rowIndexAmongNonSent × 6`, so the first non-sent row is always `0`).
    /// Amounts come from the persisted proposal (schedule rows) or the sent record itself (leading
    /// rows) — never from live progress.
    static func transferRows(
        committedSchedule: MigrationCommittedSchedule,
        state: MigrationState,
        hasOverdueMigrationTransfers: Bool,
        now: Date
    ) -> [MigrationTransferRow] {
        struct RowSeed {
            let transferId: String
            let amount: Zatoshi
            let sentRecord: MigrationCommittedSchedule.SentRecord?
        }

        let scheduleTransferIds = Set(committedSchedule.schedule.transfers.map { $0.id })
        let sentRecordsByTransferId = Dictionary(
            committedSchedule.sentRecords.map { ($0.transferId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let leadingRows: [RowSeed] = committedSchedule.sentRecords
            .filter { !scheduleTransferIds.contains($0.transferId) }
            .map { RowSeed(transferId: $0.transferId, amount: $0.amount, sentRecord: $0) }
        let scheduleRows: [RowSeed] = committedSchedule.schedule.transfers.map { transfer in
            RowSeed(transferId: transfer.id, amount: transfer.amount, sentRecord: sentRecordsByTransferId[transfer.id])
        }

        let seeds = leadingRows + scheduleRows
        let firstNonSentIndex = seeds.firstIndex { $0.sentRecord == nil }

        var nonSentPosition = 0
        return seeds.enumerated().map { index, seed in
            if let sentRecord = seed.sentRecord {
                let elapsedMinutes = max(0, Int(now.timeIntervalSince(sentRecord.sentAt) / 60))
                return MigrationTransferRow(
                    id: seed.transferId,
                    index: index,
                    amount: seed.amount,
                    status: MigrationTransferRow.Status.sent,
                    hoursFromNow: elapsedMinutes / 60,
                    sentMinutesAgo: elapsedMinutes < 60 ? elapsedMinutes : nil
                )
            }

            let status = nonSentRowStatus(
                transferId: seed.transferId,
                isFirstNonSent: index == firstNonSentIndex,
                state: state,
                hasOverdueMigrationTransfers: hasOverdueMigrationTransfers
            )
            let hoursFromNow = max(0, nonSentPosition * 6)
            nonSentPosition += 1

            return MigrationTransferRow(
                id: seed.transferId,
                index: index,
                amount: seed.amount,
                status: status,
                hoursFromNow: hoursFromNow
            )
        }
    }

    private static func nonSentRowStatus(
        transferId: String,
        isFirstNonSent: Bool,
        state: MigrationState,
        hasOverdueMigrationTransfers: Bool
    ) -> MigrationTransferRow.Status {
        if case let MigrationState.requiresAttention(reason) = state,
           case let MigrationAttentionReason.invalidTransfer(invalidTransferId) = reason,
           invalidTransferId == transferId {
            return MigrationTransferRow.Status.invalid
        }

        guard isFirstNonSent else { return MigrationTransferRow.Status.pending }

        if case MigrationState.requiresAttention(MigrationAttentionReason.transferExpired) = state {
            return MigrationTransferRow.Status.expired
        }

        return hasOverdueMigrationTransfers ? MigrationTransferRow.Status.overdue : MigrationTransferRow.Status.active
    }

    /// `transferred`/`transfersSent` come straight from `sentRecords`; `transfersTotal` adds the
    /// current schedule's still-unsent transfers (excludes any already covered by a sent record, so
    /// a re-committed schedule doesn't double-count); `estimatedDurationHours` is the persisted
    /// schedule's own estimate. `dust`: `residual` (already flattened `threw-or-nil -> nil` by the
    /// caller) when available; while `state == .complete` and residual isn't, `progress
    /// .remainingOrchard` (whatever's left over at completion is the best available proxy); `.zero`
    /// otherwise.
    static func summary(
        committedSchedule: MigrationCommittedSchedule,
        state: MigrationState,
        residual: Zatoshi?,
        progress: MigrationProgress?
    ) -> MigrationSummary {
        let transferred = committedSchedule.sentRecords.reduce(Zatoshi.zero) { $0 + $1.amount }
        let sentTransferIds = Set(committedSchedule.sentRecords.map { $0.transferId })
        let unsentScheduleCount = committedSchedule.schedule.transfers.filter { !sentTransferIds.contains($0.id) }.count

        let dust: Zatoshi
        if let residual {
            dust = residual
        } else if state == MigrationState.complete {
            dust = progress?.remainingOrchard ?? Zatoshi.zero
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
}

// MARK: - Persistence + sync<->send privacy gate

/// `UserDefaults`-backed persistence for every app-owned migration flag, plus the app-owned half
/// of the sync<->send privacy gate math (MOB-1496 W3): a completed sync briefly disables migration
/// sends, for `SDKSynchronizerClient.migrationPrivacySyncBufferDuration()`. The OTHER direction — a
/// broadcast briefly disabling sync — is enforced by the SDK itself now
/// (`isMigrationSyncBlocked`/`migrationSyncBlockedStream`), not this class. Every method that
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
    }

    // MARK: Gate

    /// Persists the sync-completion timestamp `sendGate(now:buffer:)`'s window is measured from.
    /// Called once per completed sync (`MigrationManagerImpl.recordSyncCompleted()`, fed by Root's
    /// sync-completion edge in `RootInitialization.swift`) — never per tick.
    func recordSyncCompleted(at now: Date) {
        userDefaults.set(now.timeIntervalSince1970, forKey: .migrationLastSyncCompletedAt)
    }

    /// The (b) half of `sendGate()` — see `MigrationManagerImpl.sendGate()` for the (a) "actively
    /// syncing right now" half, which needs a live SDK read this storage has no access to.
    /// Precedence: no sync ever recorded (fresh install, never synced) -> `.allowed`; `now <
    /// lastSyncCompletedAt + buffer` -> `.waitUntil(gateUntil)`; else `.allowed`.
    func sendGate(now: Date, buffer: TimeInterval) -> MigrationSendGate {
        guard let lastSyncCompletedAt = storedLastSyncCompletedAt() else {
            return MigrationSendGate.allowed
        }

        let gateUntil = lastSyncCompletedAt.addingTimeInterval(buffer)
        guard now < gateUntil else {
            return MigrationSendGate.allowed
        }

        return MigrationSendGate.waitUntil(gateUntil)
    }

    private func storedLastSyncCompletedAt() -> Date? {
        guard let interval = userDefaults.object(forKey: .migrationLastSyncCompletedAt) as? Double else {
            return nil
        }

        return Date(timeIntervalSince1970: interval)
    }

    // MARK: Mode / manual delivery / network privacy / acknowledge / dust-lock

    func migrationMode() -> MigrationMode? {
        guard let rawValue = userDefaults.string(forKey: .migrationMode) else { return nil }
        return MigrationMode(rawValue: rawValue)
    }

    func setMigrationMode(_ mode: MigrationMode) {
        userDefaults.set(mode.rawValue, forKey: .migrationMode)
    }

    func isManualDelivery() -> Bool {
        userDefaults.bool(forKey: .migrationManualDelivery)
    }

    func setManualDelivery(_ isManual: Bool) {
        userDefaults.set(isManual, forKey: .migrationManualDelivery)
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

    /// MOB-1487/MOB-1496: "Lock balance" acknowledged on Migration Complete — the dust remainder is
    /// marked unspendable and the complete screen re-enters on its locked confirmation instead of
    /// re-offering resolution. Relocated here from the (inert, pre-real-SDK) `SDKSynchronizerClient`
    /// stub — this was always app-only bookkeeping, never an SDK call.
    func isDustLocked() -> Bool {
        userDefaults.bool(forKey: .migrationDustLocked)
    }

    func setDustLocked(_ isLocked: Bool) {
        userDefaults.set(isLocked, forKey: .migrationDustLocked)
    }

    /// Clears every WALLET-WIDE persisted migration flag this storage owns: mode, manual delivery,
    /// network privacy, dust-locked, PLUS the legacy (pre-R8-T3, unsuffixed) complete-acknowledged
    /// key — dead weight now that the flag is per-account (`acknowledgedStorage`), kept here only so
    /// no stray value lingers. The actual per-account acknowledged flags are cleared by
    /// `MigrationManagerImpl.resetPersistedFlags()`, which knows the account set this storage does
    /// not. Backs the migration SDK simulator's debug panel "Reset app migration flags" control
    /// (MOB-1480). Deliberately leaves `migrationLastSyncCompletedAt` alone: the send gate's timing
    /// window is a short-lived value, not a durable app flag, and expires (the buffer elapses) on
    /// its own — same reasoning the retired `migrationSyncGateUntil` followed pre-MOB-1496 (W3).
    func resetPersistedFlags() {
        userDefaults.removeObject(forKey: .migrationMode)
        userDefaults.removeObject(forKey: .migrationManualDelivery)
        userDefaults.removeObject(forKey: .migrationNetworkPrivacyOptions)
        userDefaults.removeObject(forKey: .migrationCompleteAcknowledged)
        userDefaults.removeObject(forKey: .migrationDustLocked)
    }
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
    func modify(for accountUUID: AccountUUID, _ body: @Sendable (inout Payload?) -> Void) {
        lock.withLock { _ in
            var payload = readPayload(for: accountUUID)
            body(&payload)
            if let payload {
                writePayload(payload, for: accountUUID)
            } else {
                userDefaults.removeObject(forKey: key(for: accountUUID))
            }
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

    /// REPLACES `schedule`/`committedAt`; PRESERVES `sentRecords` from any existing payload (a
    /// restart/re-created plan continues the same logical run — the re-created-plan UI shows prior
    /// sent rows with checks); starts fresh with empty `sentRecords` when no payload exists yet.
    func recordCommittedSchedule(_ schedule: MigrationSchedule, for accountUUID: AccountUUID, now: Date) {
        storage.modify(for: accountUUID) { payload in
            let sentRecords = payload?.sentRecords ?? []
            payload = MigrationCommittedSchedule(schedule: schedule, sentRecords: sentRecords, committedAt: now)
        }
    }

    /// Appends a `SentRecord` for the FIRST transfer in the persisted schedule that has no sent
    /// record yet (matched by order), on `.success(txId:)` only — every other result, and a missing
    /// payload (nothing to append against), is a no-op. An empty `txId` (the record-failed-after-
    /// broadcast placeholder — the broadcast landed, only the engine's own recording of it failed)
    /// persists as `nil` rather than an empty string.
    func recordTransferBroadcast(_ result: MigrationTransferResult, for accountUUID: AccountUUID, now: Date) {
        storage.modify(for: accountUUID) { payload in
            guard case let MigrationTransferResult.success(txId) = result else { return }
            guard var current = payload else { return }

            let sentTransferIds = Set(current.sentRecords.map { $0.transferId })
            guard let transfer = current.schedule.transfers.first(where: { !sentTransferIds.contains($0.id) }) else { return }

            let sentRecord = MigrationCommittedSchedule.SentRecord(
                transferId: transfer.id,
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

    /// Persists `snapshot` for `accountUUID`, REPLACING any existing one. Callers are responsible
    /// for the idempotent ensure-or-create semantics (`MigrationManagerImpl.ensureNetworkSnapshot`)
    /// — this storage itself is a plain, unconditional write.
    func recordSnapshot(_ snapshot: MigrationNetworkSnapshot, for accountUUID: AccountUUID) {
        storage.write(snapshot, for: accountUUID)
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

    /// SET on any LANDED broadcast, on every lane (FG send, note split, BG — see
    /// `MigrationManagerImpl.recordTransferBroadcast`, the single call site). Also resets the R16
    /// episode: a fresh episode starts with every new transfer attempt window.
    ///
    /// R7 final review, Important-1: also clears the Tor-hold indicator — a landed broadcast is the
    /// freshest possible signal that Tor (if on) is reachable right now, so any previously-persisted
    /// hold no longer describes reality. Same lock acquisition as the two clears above (one
    /// read-modify-write, not three).
    func markHadBroadcast(for accountUUID: AccountUUID) {
        lock.withLock { _ in
            userDefaults.set(true, forKey: hadBroadcastKey(for: accountUUID))
            userDefaults.removeObject(forKey: episodeKey(for: accountUUID))
            userDefaults.removeObject(forKey: torHoldKey(for: accountUUID))
        }
    }

    /// CLEARED at the run-end trio (`MigrationManagerImpl.acknowledgeComplete`/`resetPersistedFlags`/
    /// `reconcile`'s stale-`.notStarted` observation), beside the existing schedule/snapshot clears.
    /// Clears the flag, the episode, and the Tor-hold indicator.
    func clear(for accountUUID: AccountUUID) {
        lock.withLock { _ in
            userDefaults.removeObject(forKey: hadBroadcastKey(for: accountUUID))
            userDefaults.removeObject(forKey: episodeKey(for: accountUUID))
            userDefaults.removeObject(forKey: torHoldKey(for: accountUUID))
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
}
