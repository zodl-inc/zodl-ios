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
            reentryRoute: { impl.reentryRoute() },
            isIronwoodActivated: { impl.isIronwoodActivated() },
            orchardBalanceToMigrate: { accountUUID in await impl.orchardBalanceToMigrate(accountUUID: accountUUID) },
            migrationMode: { impl.gateStorage.migrationMode() },
            setMigrationMode: { impl.gateStorage.setMigrationMode($0) },
            isManualDelivery: { impl.gateStorage.isManualDelivery() },
            setManualDelivery: { impl.gateStorage.setManualDelivery($0) },
            networkPrivacyOptions: { impl.gateStorage.networkPrivacyOptions() },
            setNetworkPrivacyOptions: { impl.gateStorage.setNetworkPrivacyOptions($0) },
            isCompleteAcknowledged: { impl.gateStorage.isCompleteAcknowledged() },
            acknowledgeComplete: { impl.gateStorage.acknowledgeComplete() },
            sendGate: { impl.sendGate() },
            recordMigrationBroadcast: { impl.recordMigrationBroadcast() },
            isSyncDeferredAfterBroadcast: { impl.isSyncDeferredAfterBroadcast() },
            reconcile: { impl.reconcile() },
            resetPersistedFlags: { impl.resetPersistedFlags() }
        )
    }
}

/// Composes `sdkSynchronizer` + `MigrationGateStorage` and owns the lazy `stateStream()`
/// subscription that drives the sync<->send gate. `@unchecked Sendable`: the only mutable state
/// is `gateStorage`'s own `OSAllocatedUnfairLock`-protected storage plus the Combine
/// subscription handle below, both of which are safe to share across isolation domains.
final class MigrationManagerImpl: @unchecked Sendable {
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    let gateStorage: MigrationGateStorage

    /// Internal (not private) with injectable storage so unit tests can exercise the real
    /// `reconcile()` against a scoped `UserDefaults` suite.
    init(gateStorage: MigrationGateStorage = MigrationGateStorage()) {
        self.gateStorage = gateStorage
    }

    private let subscriptionState = OSAllocatedUnfairLock<AnyCancellable?>(initialState: nil)

    /// Subscribes to `sdkSynchronizer.stateStream()` on first use so gate transitions (pending ->
    /// resolved) are observed as soon as anything asks this client for a derivation or the gate,
    /// without requiring reducer glue to kick it off (the `shieldingProcessor` precedent).
    private func ensureSubscribed() {
        subscriptionState.withLock { cancellable in
            guard cancellable == nil else { return }

            let gateStorage = self.gateStorage
            cancellable = self.sdkSynchronizer.stateStream()
                .sink { state in
                    gateStorage.observeSyncStatus(state.syncStatus.isSyncing == false, at: Date())
                }
        }
    }

    func bannerVariant(accountUUID: AccountUUID?) async -> MigrationBannerVariant? {
        ensureSubscribed()

        let state = normalizedState()
        let rows = sdkSynchronizer.migrationTransfers()
        let balance = await orchardBalanceToMigrate(accountUUID: accountUUID)

        return MigrationDerivations.bannerVariant(
            isIronwoodActivated: isIronwoodActivated(),
            state: state,
            hasInvalid: sdkSynchronizer.hasInvalidMigrationTransfers(),
            hasOverdue: sdkSynchronizer.hasOverdueMigrationTransfers(),
            isManualDelivery: gateStorage.isManualDelivery(),
            isNextTransferDue: isNextTransferDue(),
            orchardBalance: balance,
            isCompleteAcknowledged: gateStorage.isCompleteAcknowledged(),
            transferRows: rows
        )
    }

    func reentryRoute() -> MigrationReentryRoute {
        ensureSubscribed()

        let progress = sdkSynchronizer.getMigrationProgress()

        return MigrationDerivations.reentryRoute(
            isIronwoodActivated: isIronwoodActivated(),
            state: normalizedState(),
            hasInvalid: sdkSynchronizer.hasInvalidMigrationTransfers(),
            hasOverdue: sdkSynchronizer.hasOverdueMigrationTransfers(),
            isManualDelivery: gateStorage.isManualDelivery(),
            isNextTransferDue: isNextTransferDue(),
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

    func sendGate() -> MigrationSendGate {
        ensureSubscribed()

        if sdkSynchronizer.isSyncRequiredBeforeNextMigrationTransfer() {
            gateStorage.markSyncRequired()
        }

        return gateStorage.sendGate(now: Date())
    }

    func recordMigrationBroadcast() {
        gateStorage.recordMigrationBroadcast(at: Date())
    }

    func isSyncDeferredAfterBroadcast() -> Bool {
        gateStorage.isSyncDeferredAfterBroadcast(now: Date())
    }

    func reconcile() {
        // MOB-1483: pre-activation there is nothing to reconcile — the SDK has no migration state
        // to initialize or acknowledge yet, so skip both entirely rather than touch the SDK/storage
        // on every launch before Ironwood activates.
        guard isIronwoodActivated() else { return }

        sdkSynchronizer.initializeMigrationPostUpgrade()

        // Stale-acknowledge reset: the acknowledged flag must never suppress a *new* migration's
        // completion banner (reinstall, Path F). It's only meaningful while state is `.complete`.
        if sdkSynchronizer.getMigrationState() != MigrationState.complete {
            gateStorage.clearAcknowledgedComplete()
        }
    }

    /// MOB-1480: the migration SDK simulator's debug panel "Reset app migration flags" control.
    func resetPersistedFlags() {
        gateStorage.resetPersistedFlags()
    }

    /// `.requiresAttention(.syncRequiredBeforeNext)` carries no progress payload of its own, but
    /// per spec it renders identically to a plain `.inProgress(p)` banner — so it's normalized to
    /// that shape here, using the SDK's own out-of-band `getMigrationProgress()` snapshot, before
    /// ever reaching `MigrationDerivations` (which only needs to know about `.inProgress`).
    private func normalizedState() -> MigrationState {
        let state = sdkSynchronizer.getMigrationState()

        guard case MigrationState.requiresAttention(AttentionReason.syncRequiredBeforeNext) = state,
              let progress = sdkSynchronizer.getMigrationProgress() else {
            return state
        }

        return MigrationState.inProgress(progress)
    }

    /// "Next due" (manual): ready height already reached (or unknown / no progress -> not due).
    private func isNextTransferDue() -> Bool {
        // MOB-1480: `nextTransferReadyAtHeight` is a synthetic (epoch-seconds) height while the
        // simulator is active, which can never compare true against the real chain's
        // `latestBlockHeight` below — ask the engine directly instead.
        if MigrationSimulatorFlag.isEnabled && MigrationSimulatorClient.sharedEngine.isActive {
            return MigrationSimulatorClient.sharedEngine.isNextTransferDue()
        }

        guard let readyAtHeight = sdkSynchronizer.getMigrationProgress()?.nextTransferReadyAtHeight else {
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
        let tip = sdkSynchronizer.latestState().latestBlockHeight
        return tip > 0 && tip >= zcashSDKEnvironment.ironwoodActivationHeight()
    }
}

// MARK: - Pure derivations (table-testable, no SDK dependency)

/// Pure mappings from SDK-observed migration state (plus a handful of app-side flags) onto what
/// the UI shows. Every function here is a straight table lookup — no dates, no I/O, no SDK types
/// beyond the value models already `Equatable`/`Sendable` (`MigrationState`, `MigrationProgress`,
/// `AttentionReason`, `MigrationTransferRow`) — so `MigrationManagerTests` can exercise every row
/// directly.
enum MigrationDerivations {
    /// See MOB-1466 spec, "bannerVariant derivation" table. `isIronwoodActivated` (MOB-1483) is
    /// checked first and gates the whole derivation — pre-activation there is no banner.
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
            if isManualDelivery && isNextTransferDue {
                return MigrationBannerVariant.transferReady(number: progress.completedTransfers + 1)
            }
            return MigrationBannerVariant.inProgress(done: progress.completedTransfers, total: progress.totalTransfers)

        case let MigrationState.requiresAttention(reason):
            switch reason {
            case let AttentionReason.transferStalled(transferNumber):
                return MigrationBannerVariant.transferWaiting(number: transferNumber)

            case AttentionReason.invalidTransfer:
                return MigrationBannerVariant.updatePlan

            case AttentionReason.transferExpired:
                let (first, last) = expiredBounds(transferRows: transferRows)
                return MigrationBannerVariant.transfersExpired(first: first, last: last)

            case AttentionReason.syncRequiredBeforeNext:
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
        return reason == AttentionReason.transferExpired
    }
}

// MARK: - Persistence + 10-minute sync<->send gate

/// `UserDefaults`-backed persistence for every app-owned migration flag, plus the 10-minute
/// sync<->send gate math. Every method that depends on "now" takes it as a parameter — never
/// reads `Date()` internally — so tests can drive the clock explicitly. Injectable
/// `UserDefaults` (default `.standard`) lets tests use an isolated named suite.
final class MigrationGateStorage: @unchecked Sendable {
    private enum Constants {
        static let tenMinutes: TimeInterval = 10 * 60
    }

    private let userDefaults: UserDefaults
    /// Transient (not persisted): "a required-before-transfer sync is currently pending
    /// resolution". Re-derived from a fresh SDK read on every `markSyncRequired()` call, so
    /// losing it across relaunch is fine — the LiveKey re-observes the live SDK flag immediately.
    private let isSyncCurrentlyRequired = OSAllocatedUnfairLock(initialState: false)

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: Gate

    /// Called whenever the LiveKey observes `isSyncRequiredBeforeNextMigrationTransfer() == true`.
    /// Marks the gate as required outright — `sendGate()` checks this before the persisted
    /// `gateUntil` window.
    func markSyncRequired() {
        isSyncCurrentlyRequired.withLock { $0 = true }
    }

    /// Called from the `stateStream()` subscription: `isSyncFinished` reflects whether the just
    /// observed `SyncStatus` is no longer `.syncing` (i.e. reached up-to-date). Only takes effect
    /// while a sync requirement is pending — an unrelated "already idle" tick is a no-op.
    func observeSyncStatus(_ isSyncFinished: Bool, at now: Date) {
        guard isSyncFinished else { return }

        let wasPending = isSyncCurrentlyRequired.withLock { pending -> Bool in
            let wasPending = pending
            pending = false
            return wasPending
        }

        guard wasPending else { return }

        recordSyncCompletion(at: now)
    }

    /// Persists `gateUntil = syncCompletion + 10 min` and clears the pending flag. Exposed
    /// separately from `observeSyncStatus` so tests can drive the gate without a fake stream tick.
    func recordSyncCompletion(at syncCompletedAt: Date) {
        isSyncCurrentlyRequired.withLock { $0 = false }
        let gateUntil = syncCompletedAt.addingTimeInterval(Constants.tenMinutes)
        userDefaults.set(gateUntil.timeIntervalSince1970, forKey: .migrationSyncGateUntil)
    }

    /// `sendGate()` precedence: sync currently required -> `.syncRequired`; `now < gateUntil` ->
    /// `.waitUntil(gateUntil)`; else `.allowed`.
    func sendGate(now: Date) -> MigrationSendGate {
        if isSyncCurrentlyRequired.withLock({ $0 }) {
            return MigrationSendGate.syncRequired
        }

        guard let gateUntil = storedGateUntil(), now < gateUntil else {
            return MigrationSendGate.allowed
        }

        return MigrationSendGate.waitUntil(gateUntil)
    }

    private func storedGateUntil() -> Date? {
        guard let interval = userDefaults.object(forKey: .migrationSyncGateUntil) as? Double else {
            return nil
        }

        return Date(timeIntervalSince1970: interval)
    }

    // MARK: Broadcast timestamp (consumed by MOB-1467)

    /// Persisted (not merely in-memory) so relaunching the app cannot dodge the post-broadcast
    /// sync deferral MOB-1467's scheduler will apply.
    func recordMigrationBroadcast(at now: Date) {
        userDefaults.set(now.timeIntervalSince1970, forKey: .migrationLastBroadcastAt)
    }

    /// Sync side of the 10-minute sync<->send separation (feature spec section 8.2): background
    /// syncs must not start sooner than 10 minutes after a foreground migration broadcast.
    /// MOB-1467's scheduler is the consumer; nothing reads this in MOB-1466.
    func isSyncDeferredAfterBroadcast(now: Date) -> Bool {
        guard let interval = userDefaults.object(forKey: .migrationLastBroadcastAt) as? Double else {
            return false
        }

        return now < Date(timeIntervalSince1970: interval).addingTimeInterval(Constants.tenMinutes)
    }

    // MARK: Mode / manual delivery / network privacy / acknowledge

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

    func networkPrivacyOptions() -> NetworkPrivacyOptions {
        guard let data = userDefaults.data(forKey: .migrationNetworkPrivacyOptions),
              let options = try? JSONDecoder().decode(NetworkPrivacyOptions.self, from: data) else {
            return NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil)
        }

        return options
    }

    func setNetworkPrivacyOptions(_ options: NetworkPrivacyOptions) {
        guard let data = try? JSONEncoder().encode(options) else { return }
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

    /// Clears every persisted migration flag this storage owns: mode, manual delivery, network
    /// privacy, complete-acknowledged, last-broadcast. Backs the migration SDK simulator's debug
    /// panel "Reset app migration flags" control (MOB-1480). Deliberately leaves
    /// `migrationSyncGateUntil`/the transient sync-required flag alone: the 10-minute send gate is
    /// a short-lived timing window, not a durable app flag, and expires on its own.
    func resetPersistedFlags() {
        userDefaults.removeObject(forKey: .migrationMode)
        userDefaults.removeObject(forKey: .migrationManualDelivery)
        userDefaults.removeObject(forKey: .migrationNetworkPrivacyOptions)
        userDefaults.removeObject(forKey: .migrationCompleteAcknowledged)
        userDefaults.removeObject(forKey: .migrationLastBroadcastAt)
    }
}
