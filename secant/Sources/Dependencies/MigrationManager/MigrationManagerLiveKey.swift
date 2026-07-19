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
            activeNetworkSnapshots: { impl.activeNetworkSnapshots() },
            setNetworkPrivacyOptions: { impl.setNetworkPrivacyOptions(useTor: $0) },
            isCompleteAcknowledged: { impl.gateStorage.isCompleteAcknowledged() },
            acknowledgeComplete: { impl.acknowledgeComplete() },
            sendGate: { await impl.sendGate() },
            recordSyncCompleted: { impl.recordSyncCompleted() },
            reconcile: { await impl.reconcile() },
            resetPersistedFlags: { impl.resetPersistedFlags() }
        )
    }
}

/// Composes `sdkSynchronizer` + `MigrationGateStorage` and owns the per-account `stateEvents`
/// subjects. `@unchecked Sendable`: the only mutable state is `gateStorage`'s own
/// `OSAllocatedUnfairLock`-protected storage plus the Combine subjects below, all of which are
/// safe to share across isolation domains.
final class MigrationManagerImpl: @unchecked Sendable {
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
    @Dependency(\.userStoredPreferences) var userStoredPreferences
    @Dependency(\.transactionGuard) var transactionGuard

    @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
    @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []

    let gateStorage: MigrationGateStorage
    /// MOB-1496 (W2): per-account persisted committed schedule — see `MigrationScheduleStorage`.
    let scheduleStorage: MigrationScheduleStorage
    /// MOB-1496 (W4): per-account persisted atomic network snapshot — see `MigrationSnapshotStorage`.
    let snapshotStorage: MigrationSnapshotStorage

    /// Internal (not private) with injectable storage so unit tests can exercise the real
    /// `reconcile()` against a scoped `UserDefaults` suite.
    init(
        gateStorage: MigrationGateStorage = MigrationGateStorage(),
        scheduleStorage: MigrationScheduleStorage = MigrationScheduleStorage(),
        snapshotStorage: MigrationSnapshotStorage = MigrationSnapshotStorage()
    ) {
        self.gateStorage = gateStorage
        self.scheduleStorage = scheduleStorage
        self.snapshotStorage = snapshotStorage
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

    func bannerVariant(accountUUID: AccountUUID?) async -> MigrationBannerVariant? {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return nil }
        guard let state = await normalizedState(accountUUID: resolvedAccountUUID) else { return nil }

        let rows = await migrationTransfers(accountUUID: resolvedAccountUUID)
        let balance = await orchardBalanceToMigrate(accountUUID: resolvedAccountUUID)

        return MigrationDerivations.bannerVariant(
            isIronwoodActivated: isIronwoodActivated(),
            state: state,
            hasInvalid: await hasInvalidMigrationTransfers(accountUUID: resolvedAccountUUID),
            hasOverdue: await hasOverdueMigrationTransfers(accountUUID: resolvedAccountUUID),
            isManualDelivery: gateStorage.isManualDelivery(),
            isNextTransferDue: await isNextTransferDue(accountUUID: resolvedAccountUUID),
            orchardBalance: balance,
            isCompleteAcknowledged: gateStorage.isCompleteAcknowledged(),
            transferRows: rows
        )
    }

    func reentryRoute() async -> MigrationReentryRoute {
        guard let accountUUID = selectedWalletAccount?.id else { return MigrationReentryRoute.entry }

        let state = await normalizedState(accountUUID: accountUUID) ?? MigrationState.notStarted
        let progress = await migrationProgress(accountUUID: accountUUID)

        return MigrationDerivations.reentryRoute(
            isIronwoodActivated: isIronwoodActivated(),
            state: state,
            hasInvalid: await hasInvalidMigrationTransfers(accountUUID: accountUUID),
            hasOverdue: await hasOverdueMigrationTransfers(accountUUID: accountUUID),
            isManualDelivery: gateStorage.isManualDelivery(),
            isNextTransferDue: await isNextTransferDue(accountUUID: accountUUID),
            isCompleteAcknowledged: gateStorage.isCompleteAcknowledged(),
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
            // [MOB-1496] W1 fallback: no persisted payload yet — rows are synthesized purely from
            // `getMigrationProgress`'s counts: index < completedTransfers reads `.sent`, everything
            // else `.pending` (no `.active`/`.overdue`/`.invalid`/`.expired` — those need per-
            // transfer identity a persisted schedule would carry); `hoursFromNow` is a rough
            // `(index - completed) × 6h` cadence estimate, clamped ≥ 0. `amount`/`id` are
            // placeholders. On a missing account or any SDK-read error, `[]`.
            guard let progress = await migrationProgress(accountUUID: resolvedAccountUUID) else { return [] }

            return (0..<progress.totalTransfers).map { index in
                MigrationTransferRow(
                    id: "\(index)",
                    index: index,
                    amount: Zatoshi.zero,
                    status: index < progress.completedTransfers ? MigrationTransferRow.Status.sent : MigrationTransferRow.Status.pending,
                    hoursFromNow: max(0, (index - progress.completedTransfers) * 6)
                )
            }
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

    /// MOB-1496 (W2): persists the just-committed schedule for `accountUUID` (`nil` resolves the
    /// selected account, same convention as `migrationSummary`/`migrationTransfers` above) — the
    /// SDK retains no proposal list post-commit, so this is the app's only record of it. Replaces
    /// any existing payload's `schedule`/`committedAt` while preserving its `sentRecords` (a
    /// restart/re-created plan continues the same logical run).
    func recordCommittedSchedule(accountUUID: AccountUUID?, schedule: MigrationSchedule) async {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
        scheduleStorage.recordCommittedSchedule(schedule, for: resolvedAccountUUID, now: Date())
    }

    /// MOB-1496 (W2): records a successful transfer broadcast against the persisted schedule
    /// (appends a `SentRecord` for the first not-yet-sent transfer, in schedule order); non-success
    /// results and a missing payload (nothing to append against) are both no-ops — see
    /// `MigrationScheduleStorage.recordTransferBroadcast`.
    func recordTransferBroadcast(accountUUID: AccountUUID?, result: MigrationTransferResult) async {
        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return }
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

    /// MOB-1496 (W4): every persisted network snapshot across `walletAccounts`, plus the selected
    /// account defensively (deduped) — i.e. every account with a currently-active migration run.
    /// Drives `AutoServerSelectionLiveKey`'s pinning and `ServerSetupStore`'s manual-switch privacy
    /// warning.
    func activeNetworkSnapshots() -> [MigrationNetworkSnapshot] {
        var seenAccountUUIDs = Set<AccountUUID>()
        var accountUUIDs = walletAccounts.map { $0.id }
        if let selectedAccountUUID = selectedWalletAccount?.id {
            accountUUIDs.append(selectedAccountUUID)
        }

        var snapshots: [MigrationNetworkSnapshot] = []
        for accountUUID in accountUUIDs {
            guard seenAccountUUIDs.insert(accountUUID).inserted else { continue }
            if let snapshot = snapshotStorage.snapshot(for: accountUUID) {
                snapshots.append(snapshot)
            }
        }
        return snapshots
    }

    /// Persists the pre-run Tor choice — consumed the next time THIS account's snapshot is first
    /// taken (`createNetworkSnapshot`'s `useTor` read). Does not alter an already-active run's
    /// snapshot (see `MigrationNetworkSnapshot.useTor`'s doc).
    func setNetworkPrivacyOptions(useTor: Bool) {
        gateStorage.setTorEnabledForMigration(useTor)
    }

    /// Idempotent ensure-or-create for `accountUUID`'s (resolved, if `nil`, to the selected account)
    /// atomic per-run network snapshot. Returns the persisted snapshot when one already exists;
    /// otherwise creates one from the CURRENT sync endpoint/Tor choice, persists it, and returns it.
    /// Double-checks presence again AFTER acquiring the guard (not just before) — a concurrent first
    /// caller for the SAME account may have already created and persisted one while this call
    /// waited, and that one must win rather than being silently overwritten. A missing/unresolvable
    /// account still returns SOME snapshot (the current endpoint/Tor choice, unpersisted) — every
    /// path ends in a value, never a throw.
    private func ensureNetworkSnapshot(accountUUID: AccountUUID?) async -> MigrationNetworkSnapshot {
        let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id

        if let resolvedAccountUUID, let existing = snapshotStorage.snapshot(for: resolvedAccountUUID) {
            return existing
        }

        // DO-NOT-NEST: see `migrationNetworkOptions`'s doc — this must never run inside another
        // `withSubmission`/`switchIfIdle`/`switchWaiting`.
        let guarded = try? await transactionGuard.withSubmission { () async -> MigrationNetworkSnapshot in
            if let resolvedAccountUUID, let existing = snapshotStorage.snapshot(for: resolvedAccountUUID) {
                return existing
            }
            let created = await createNetworkSnapshot()
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
        return await createNetworkSnapshot()
    }

    /// The actual read+benchmark sequence for a fresh snapshot — see `ensureNetworkSnapshot`'s doc
    /// for the guard this always runs inside. Never throws; every path ends in a snapshot.
    private func createNetworkSnapshot() async -> MigrationNetworkSnapshot {
        let currentEndpoint = zcashSDKEnvironment.endpoint()
        let storedServerConfig = userStoredPreferences.server()
        let useTor = gateStorage.isTorEnabledForMigration()
        let syncProvider = ServerProvider.classify(host: currentEndpoint.host)

        var syncProviderIsCustom = false
        if case ServerProvider.custom = syncProvider {
            syncProviderIsCustom = true
        }
        let isCustomServer = syncProviderIsCustom || (storedServerConfig?.isCustom ?? false)

        let broadcastEndpoint: LightWalletEndpoint
        let broadcastProvider: ServerProvider

        if isCustomServer {
            // Michal's rule: a user-selected custom server is used for ALL operations — sync and
            // every migration broadcast — no separation.
            broadcastEndpoint = currentEndpoint
            broadcastProvider = syncProvider
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
                broadcastProvider = syncProvider
            } else {
                // Reuse exactly the constants/shape `AutoServerSelectionLiveKey.findBestServer`'s
                // background benchmark uses.
                let ranked = await sdkSynchronizer.evaluateBestOf(
                    candidates,
                    AutoServerSelectionConstants.evaluationTimeoutSeconds,
                    AutoServerSelectionConstants.blocksToDownload,
                    AutoServerSelectionConstants.candidateCount,
                    network
                )
                if let best = ranked.first {
                    broadcastEndpoint = best
                } else {
                    LoggerProxy.event(
                        "[MigrationNetworkSnapshot] Broadcast benchmark produced no result — falling back to \(candidates[0].host)"
                    )
                    broadcastEndpoint = candidates[0]
                }
                broadcastProvider = ServerProvider.classify(host: broadcastEndpoint.host)
            }
        }

        return MigrationNetworkSnapshot(
            useTor: useTor,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(currentEndpoint),
            syncProvider: syncProvider,
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(broadcastEndpoint),
            broadcastProvider: broadcastProvider,
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

    /// Re-reads `getMigrationState` for the selected account (single-account semantics — MOB-1496
    /// W1; a later task fans this out per-account) and, when it differs from the account, the
    /// Keystone-vendor account too, pushing each into its `stateEvents` subject on either a state
    /// or balance-to-migrate change (MOB-1496 W2 emit-fix — see `pushStateIfChanged`'s doc).
    /// Also runs the stale-acknowledge reset (selected account only, since the acknowledged flag
    /// is not yet per-account): the acknowledged flag must never suppress a *new* migration's
    /// completion banner (reinstall, Path F) — only meaningful while state is `.complete`. Called
    /// on every foreground entry / launch (`RootInitialization.swift`) and after a store reports a
    /// completed migration op (`MigrationSendingStore`/`MigrationNoteSplitStore`).
    func reconcile() async {
        guard isIronwoodActivated() else { return }

        let selectedAccountUUID = selectedWalletAccount?.id
        var accountsToRefresh: [AccountUUID] = []
        if let selectedAccountUUID {
            accountsToRefresh.append(selectedAccountUUID)
        }
        if let keystoneAccountUUID = walletAccounts.first(where: { $0.vendor == WalletAccount.Vendor.keystone })?.id,
           keystoneAccountUUID != selectedAccountUUID {
            accountsToRefresh.append(keystoneAccountUUID)
        }

        for accountUUID in accountsToRefresh {
            guard let state = await migrationState(accountUUID: accountUUID) else { continue }

            let hasBalanceToMigrate = await orchardBalanceToMigrate(accountUUID: accountUUID) > Zatoshi.zero
            pushStateIfChanged(state, hasBalanceToMigrate: hasBalanceToMigrate, for: accountUUID)

            if accountUUID == selectedAccountUUID && state != MigrationState.complete {
                gateStorage.clearAcknowledgedComplete()
            }

            // MOB-1496 (W2): a run abandoned/reset out from under a stale persisted schedule — the
            // engine is authoritative, so `.notStarted` observed against an account that still has
            // a stored payload means that payload no longer corresponds to anything the engine
            // knows about (e.g. a debug reset, or a fresh install reusing a restored seed).
            // MOB-1496 (W4): the network snapshot's lifetime is tied to the same logical run as the
            // schedule payload — clear it beside the schedule (a later dust mini-run then takes a
            // FRESH snapshot, which is correct).
            if state == MigrationState.notStarted && scheduleStorage.hasStoredPayload(for: accountUUID) {
                scheduleStorage.clear(for: accountUUID)
                snapshotStorage.clear(for: accountUUID)
            }
        }
    }

    /// MOB-1496 (W2): bundles the existing wallet-wide acknowledge-complete flag with clearing the
    /// SELECTED account's persisted schedule — the run the Complete screen was showing has ended,
    /// so its committed schedule/sent records must not leak into a future run's rows (a fresh
    /// migration, e.g. after reinstall, must start from an empty logical run). The acknowledged
    /// flag itself stays wallet-wide (see `reconcile()`'s doc); only the schedule clear is
    /// account-scoped here. MOB-1496 (W4): also clears the account's network snapshot — a later
    /// "Migrate anyway" dust mini-run then takes a FRESH one.
    func acknowledgeComplete() {
        gateStorage.acknowledgeComplete()
        if let accountUUID = selectedWalletAccount?.id {
            scheduleStorage.clear(for: accountUUID)
            snapshotStorage.clear(for: accountUUID)
        }
    }

    /// MOB-1480: the migration SDK simulator's debug panel "Reset app migration flags" control.
    /// MOB-1496 (W2): also clears every known account's persisted schedule — a debug reset must
    /// leave no stale committed-schedule payload behind either. MOB-1496 (W4): and its network
    /// snapshot.
    func resetPersistedFlags() {
        gateStorage.resetPersistedFlags()
        for account in walletAccounts {
            scheduleStorage.clear(for: account.id)
            snapshotStorage.clear(for: account.id)
        }
        if let accountUUID = selectedWalletAccount?.id {
            scheduleStorage.clear(for: accountUUID)
            snapshotStorage.clear(for: accountUUID)
        }
    }

    /// `.requiresAttention(.syncRequiredBeforeNext)` carries no progress payload of its own, but
    /// per spec it renders identically to a plain `.inProgress(p)` banner — so it's normalized to
    /// that shape here, using the SDK's own out-of-band `getMigrationProgress()` snapshot, before
    /// ever reaching `MigrationDerivations` (which only needs to know about `.inProgress`). `nil`
    /// when the state read itself fails (rather than guessing a fallback state).
    private func normalizedState(accountUUID: AccountUUID) async -> MigrationState? {
        guard let state = await migrationState(accountUUID: accountUUID) else { return nil }

        guard case MigrationState.requiresAttention(MigrationAttentionReason.syncRequiredBeforeNext) = state,
              let progress = await migrationProgress(accountUUID: accountUUID) else {
            return state
        }

        return MigrationState.inProgress(progress)
    }

    /// "Next due" (manual): ready height already reached (or unknown / no progress -> not due).
    private func isNextTransferDue(accountUUID: AccountUUID) async -> Bool {
        // MOB-1480: `nextTransferReadyAtHeight` is a synthetic (epoch-seconds) height while the
        // simulator is active, which can never compare true against the real chain's
        // `latestBlockHeight` below — ask the engine directly instead.
        if MigrationSimulatorFlag.isEnabled && MigrationSimulatorClient.sharedEngine.isActive {
            return MigrationSimulatorClient.sharedEngine.isNextTransferDue()
        }

        guard let readyAtHeight = await migrationProgress(accountUUID: accountUUID)?.nextTransferReadyAtHeight else {
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
    static func bannerVariant(
        isIronwoodActivated: Bool,
        state: MigrationState,
        hasInvalid: Bool,
        hasOverdue: Bool,
        isManualDelivery: Bool,
        isNextTransferDue: Bool,
        orchardBalance: Zatoshi,
        isCompleteAcknowledged: Bool,
        transferRows: [MigrationTransferRow]
    ) -> MigrationBannerVariant? {
        guard isIronwoodActivated else { return nil }

        switch state {
        case MigrationState.notStarted, MigrationState.readyToPropose:
            return orchardBalance > Zatoshi.zero ? MigrationBannerVariant.required : nil

        case MigrationState.splitPendingConfirmation:
            return MigrationBannerVariant.splitting

        case let MigrationState.inProgress(progress):
            if hasOverdue {
                return MigrationBannerVariant.transferWaiting(number: progress.completedTransfers + 1)
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
                // with this state — this branch only exists so the switch stays exhaustive.
                return nil
            }

        case MigrationState.complete:
            return isCompleteAcknowledged ? nil : MigrationBannerVariant.complete
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

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
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
    func isTorEnabledForMigration() -> Bool {
        guard let data = userDefaults.data(forKey: .migrationNetworkPrivacyOptions),
              let stored = try? JSONDecoder().decode(PersistedNetworkPrivacyOptions.self, from: data) else {
            return false
        }

        return stored.useTor
    }

    func setTorEnabledForMigration(_ useTor: Bool) {
        guard let data = try? JSONEncoder().encode(PersistedNetworkPrivacyOptions(useTor: useTor)) else { return }
        userDefaults.set(data, forKey: .migrationNetworkPrivacyOptions)
    }

    func isCompleteAcknowledged() -> Bool {
        userDefaults.bool(forKey: .migrationCompleteAcknowledged)
    }

    func acknowledgeComplete() {
        userDefaults.set(true, forKey: .migrationCompleteAcknowledged)
    }

    func clearAcknowledgedComplete() {
        userDefaults.set(false, forKey: .migrationCompleteAcknowledged)
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

    /// Clears every persisted migration flag this storage owns: mode, manual delivery, network
    /// privacy, complete-acknowledged, dust-locked. Backs the migration SDK simulator's debug
    /// panel "Reset app migration flags" control (MOB-1480). Deliberately leaves
    /// `migrationLastSyncCompletedAt` alone: the send gate's timing window is a short-lived value,
    /// not a durable app flag, and expires (the buffer elapses) on its own — same reasoning the
    /// retired `migrationSyncGateUntil` followed pre-MOB-1496 (W3).
    func resetPersistedFlags() {
        userDefaults.removeObject(forKey: .migrationMode)
        userDefaults.removeObject(forKey: .migrationManualDelivery)
        userDefaults.removeObject(forKey: .migrationNetworkPrivacyOptions)
        userDefaults.removeObject(forKey: .migrationCompleteAcknowledged)
        userDefaults.removeObject(forKey: .migrationDustLocked)
    }
}

// MARK: - Persistence: committed migration schedule (MOB-1496 W2)

/// Per-account `UserDefaults`-backed persistence for the confirmed migration schedule: the SDK
/// retains no proposal list once a schedule is committed, so the app persists it here —
/// `MigrationDerivations.transferRows`/`summary` derive rows/totals from this payload plus live SDK
/// reads. Same house pattern as `MigrationGateStorage`: `final class`, `@unchecked Sendable` guarded
/// by an `OSAllocatedUnfairLock` around each read-modify-write, injectable `UserDefaults` (default
/// `.standard`) so tests can use an isolated named suite. Every method that depends on "now" takes
/// it as a parameter, never reading `Date()` internally, matching `MigrationGateStorage`'s own
/// testability discipline.
final class MigrationScheduleStorage: @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let lock = OSAllocatedUnfairLock(initialState: false)

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// The persisted payload for `accountUUID`, or `nil` when none exists (fresh install mid-run,
    /// or pre-commit) — callers fall back to a progress-only derivation in that case.
    func committedSchedule(for accountUUID: AccountUUID) -> MigrationCommittedSchedule? {
        lock.withLock { _ in readPayload(for: accountUUID) }
    }

    func hasStoredPayload(for accountUUID: AccountUUID) -> Bool {
        committedSchedule(for: accountUUID) != nil
    }

    /// REPLACES `schedule`/`committedAt`; PRESERVES `sentRecords` from any existing payload (a
    /// restart/re-created plan continues the same logical run — the re-created-plan UI shows prior
    /// sent rows with checks); starts fresh with empty `sentRecords` when no payload exists yet.
    func recordCommittedSchedule(_ schedule: MigrationSchedule, for accountUUID: AccountUUID, now: Date) {
        lock.withLock { _ in
            let sentRecords = readPayload(for: accountUUID)?.sentRecords ?? []
            let payload = MigrationCommittedSchedule(schedule: schedule, sentRecords: sentRecords, committedAt: now)
            writePayload(payload, for: accountUUID)
        }
    }

    /// Appends a `SentRecord` for the FIRST transfer in the persisted schedule that has no sent
    /// record yet (matched by order), on `.success(txId:)` only — every other result, and a missing
    /// payload (nothing to append against), is a no-op. An empty `txId` (the record-failed-after-
    /// broadcast placeholder — the broadcast landed, only the engine's own recording of it failed)
    /// persists as `nil` rather than an empty string.
    func recordTransferBroadcast(_ result: MigrationTransferResult, for accountUUID: AccountUUID, now: Date) {
        lock.withLock { _ in
            guard case let MigrationTransferResult.success(txId) = result else { return }
            guard var payload = readPayload(for: accountUUID) else { return }

            let sentTransferIds = Set(payload.sentRecords.map { $0.transferId })
            guard let transfer = payload.schedule.transfers.first(where: { !sentTransferIds.contains($0.id) }) else { return }

            let sentRecord = MigrationCommittedSchedule.SentRecord(
                transferId: transfer.id,
                amount: transfer.amount,
                txId: txId.isEmpty ? nil : txId,
                sentAt: now
            )
            payload.sentRecords.append(sentRecord)
            writePayload(payload, for: accountUUID)
        }
    }

    /// Clears the run: consumed by `acknowledgeComplete()`/`resetPersistedFlags()`'s run-end/reset
    /// paths, and by `reconcile()` observing a stale `.notStarted` payload.
    func clear(for accountUUID: AccountUUID) {
        lock.withLock { _ in
            userDefaults.removeObject(forKey: key(for: accountUUID))
        }
    }

    private func readPayload(for accountUUID: AccountUUID) -> MigrationCommittedSchedule? {
        guard let data = userDefaults.data(forKey: key(for: accountUUID)),
              let payload = try? JSONDecoder().decode(MigrationCommittedSchedule.self, from: data) else {
            return nil
        }
        return payload
    }

    private func writePayload(_ payload: MigrationCommittedSchedule, for accountUUID: AccountUUID) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: key(for: accountUUID))
    }

    /// Per-account key suffix: lowercase hex of the raw 16-byte UUID, reusing `Pczt`'s existing
    /// `Data.hexEncodedString()` (`SendConfirmationStore.swift`) rather than inventing a new
    /// encoding — nothing in this file suffixes a persistence key per-account yet.
    private func key(for accountUUID: AccountUUID) -> String {
        "\(String.migrationCommittedSchedule)_\(Data(accountUUID.id).hexEncodedString())"
    }
}

// MARK: - Persistence: migration network snapshot (MOB-1496 W4)

/// Per-account `UserDefaults`-backed persistence for the atomic migration network snapshot — see
/// `MigrationNetworkSnapshot`'s doc for what it holds and why. Same house pattern as
/// `MigrationScheduleStorage` (beside which this lives): `final class`, `@unchecked Sendable` guarded
/// by an `OSAllocatedUnfairLock` around each read-modify-write, injectable `UserDefaults` (default
/// `.standard`) so tests can use an isolated named suite, same per-account key suffix idiom.
final class MigrationSnapshotStorage: @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let lock = OSAllocatedUnfairLock(initialState: false)

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// The persisted snapshot for `accountUUID`, or `nil` when none exists (no active run, or a run
    /// whose snapshot was already cleared at completion).
    func snapshot(for accountUUID: AccountUUID) -> MigrationNetworkSnapshot? {
        lock.withLock { _ in readPayload(for: accountUUID) }
    }

    /// Persists `snapshot` for `accountUUID`, REPLACING any existing one. Callers are responsible
    /// for the idempotent ensure-or-create semantics (`MigrationManagerImpl.ensureNetworkSnapshot`)
    /// — this storage itself is a plain, unconditional write.
    func recordSnapshot(_ snapshot: MigrationNetworkSnapshot, for accountUUID: AccountUUID) {
        lock.withLock { _ in writePayload(snapshot, for: accountUUID) }
    }

    /// Clears the run's snapshot: consumed by the SAME three run-end paths `MigrationScheduleStorage
    /// .clear` is (`acknowledgeComplete()`/`resetPersistedFlags()`/`reconcile()`'s stale-`.notStarted`
    /// observation) — always alongside the schedule clear, never independently.
    func clear(for accountUUID: AccountUUID) {
        lock.withLock { _ in
            userDefaults.removeObject(forKey: key(for: accountUUID))
        }
    }

    private func readPayload(for accountUUID: AccountUUID) -> MigrationNetworkSnapshot? {
        guard let data = userDefaults.data(forKey: key(for: accountUUID)),
              let payload = try? JSONDecoder().decode(MigrationNetworkSnapshot.self, from: data) else {
            return nil
        }
        return payload
    }

    private func writePayload(_ payload: MigrationNetworkSnapshot, for accountUUID: AccountUUID) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: key(for: accountUUID))
    }

    /// Per-account key suffix — same idiom as `MigrationScheduleStorage.key(for:)`.
    private func key(for accountUUID: AccountUUID) -> String {
        "\(String.migrationNetworkSnapshot)_\(Data(accountUUID.id).hexEncodedString())"
    }
}
