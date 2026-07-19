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
            lockMigrationDust: { try await impl.lockMigrationDust() },
            isMigrationDustLocked: { impl.isMigrationDustLocked() },
            stateEvents: { accountUUID in impl.stateEvents(accountUUID: accountUUID) },
            migrationMode: { impl.gateStorage.migrationMode() },
            setMigrationMode: { impl.gateStorage.setMigrationMode($0) },
            isManualDelivery: { impl.gateStorage.isManualDelivery() },
            setManualDelivery: { impl.gateStorage.setManualDelivery($0) },
            networkPrivacyOptions: { impl.networkPrivacyOptions() },
            setNetworkPrivacyOptions: { impl.setNetworkPrivacyOptions(useTor: $0) },
            isCompleteAcknowledged: { impl.gateStorage.isCompleteAcknowledged() },
            acknowledgeComplete: { impl.gateStorage.acknowledgeComplete() },
            sendGate: { await impl.sendGate() },
            recordMigrationBroadcast: { impl.recordMigrationBroadcast() },
            isSyncDeferredAfterBroadcast: { impl.isSyncDeferredAfterBroadcast() },
            reconcile: { await impl.reconcile() },
            resetPersistedFlags: { impl.resetPersistedFlags() }
        )
    }
}

/// Composes `sdkSynchronizer` + `MigrationGateStorage` and owns the lazy `stateStream()`
/// subscription that drives the sync<->send gate, plus the per-account `stateEvents` subjects.
/// `@unchecked Sendable`: the only mutable state is `gateStorage`'s own `OSAllocatedUnfairLock`-
/// protected storage plus the Combine subscription/subjects below, all of which are safe to share
/// across isolation domains.
final class MigrationManagerImpl: @unchecked Sendable {
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
    @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []

    let gateStorage: MigrationGateStorage

    /// Internal (not private) with injectable storage so unit tests can exercise the real
    /// `reconcile()` against a scoped `UserDefaults` suite.
    init(gateStorage: MigrationGateStorage = MigrationGateStorage()) {
        self.gateStorage = gateStorage
    }

    private let subscriptionState = OSAllocatedUnfairLock<AnyCancellable?>(initialState: nil)
    /// MOB-1496: one `CurrentValueSubject` per account `stateEvents` has ever been asked about,
    /// seeded `.notStarted`. `reconcile()` (and, indirectly, every store that calls it after a
    /// completed migration op) is the only writer; it emits only when a re-read's value differs
    /// from the subject's current value.
    private let stateSubjects = OSAllocatedUnfairLock<[AccountUUID: CurrentValueSubject<MigrationState, Never>]>(initialState: [:])

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
        ensureSubscribed()

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

    /// [MOB-1496] W2 replaces this with a persisted-schedule derivation. For W1, everything
    /// derivable comes from `getMigrationProgress` alone: counts and the remaining Orchard value
    /// (mapped onto `dust`). `transferred`/`estimatedDurationHours` need per-transfer amounts and
    /// the schedule's own duration estimate, neither recoverable from progress alone, so they stay
    /// `0` until W2. On a missing account or any SDK-read error, `.zero`.
    ///
    /// Simulator reach-around: the W1 derivation above is far cruder than the simulator engine's
    /// own purpose-built `summary()` (real sent/pending amounts, durations, etc. — the whole point
    /// of the simulator's demo data) — reading through the SDK members alone would otherwise
    /// silently downgrade every simulated QA session to the crude approximation. Gated exactly like
    /// `orchardBalanceToMigrate`'s existing reach-around.
    func migrationSummary(accountUUID: AccountUUID?) async -> MigrationSummary {
        if MigrationSimulatorFlag.isEnabled && MigrationSimulatorClient.sharedEngine.isActive {
            return MigrationSimulatorClient.sharedEngine.summary()
        }

        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return MigrationSummary.zero }
        guard let progress = await migrationProgress(accountUUID: resolvedAccountUUID) else { return MigrationSummary.zero }

        return MigrationSummary(
            transferred: Zatoshi.zero,
            dust: progress.remainingOrchard,
            transfersSent: progress.completedTransfers,
            transfersTotal: progress.totalTransfers,
            estimatedDurationHours: 0
        )
    }

    /// [MOB-1496] W2 replaces this with a persisted-schedule derivation. For W1, rows are
    /// synthesized purely from `getMigrationProgress`'s counts: index < completedTransfers reads
    /// `.sent`, everything else `.pending` (no `.active`/`.overdue`/`.invalid`/`.expired` — those
    /// need per-transfer identity a persisted schedule would carry); `hoursFromNow` is a rough
    /// `(index - completed) × 6h` cadence estimate (matching the real transfer spacing), clamped
    /// ≥ 0. `amount`/`id` are placeholders (`.zero` / the row's own index) pending W2. On a missing
    /// account or any SDK-read error, `[]`.
    ///
    /// Simulator reach-around — see `migrationSummary`'s doc: the engine's own `transferRows()`
    /// carries real per-row status (sent/active/overdue/invalid/expired, broadcasting, precise
    /// recency) the W1 derivation can't reproduce from counts alone.
    func migrationTransfers(accountUUID: AccountUUID?) async -> [MigrationTransferRow] {
        if MigrationSimulatorFlag.isEnabled && MigrationSimulatorClient.sharedEngine.isActive {
            return MigrationSimulatorClient.sharedEngine.transferRows()
        }

        guard let resolvedAccountUUID = accountUUID ?? selectedWalletAccount?.id else { return [] }
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

    func networkPrivacyOptions() -> MigrationNetworkPrivacyOptions {
        MigrationNetworkPrivacyOptions(useTor: gateStorage.isTorEnabledForMigration(), submissionEndpoint: zcashSDKEnvironment.endpoint())
    }

    func setNetworkPrivacyOptions(useTor: Bool) {
        gateStorage.setTorEnabledForMigration(useTor)
    }

    func sendGate() async -> MigrationSendGate {
        ensureSubscribed()

        if let accountUUID = selectedWalletAccount?.id, await isSyncRequiredBeforeNextMigrationTransfer(accountUUID: accountUUID) {
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

    /// Re-reads `getMigrationState` for the selected account (single-account semantics — MOB-1496
    /// W1; a later task fans this out per-account) and, when it differs from the account, the
    /// Keystone-vendor account too, pushing each into its `stateEvents` subject only on change.
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

            pushStateIfChanged(state, for: accountUUID)

            if accountUUID == selectedAccountUUID && state != MigrationState.complete {
                gateStorage.clearAcknowledgedComplete()
            }
        }
    }

    /// MOB-1480: the migration SDK simulator's debug panel "Reset app migration flags" control.
    func resetPersistedFlags() {
        gateStorage.resetPersistedFlags()
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

    private func isSyncRequiredBeforeNextMigrationTransfer(accountUUID: AccountUUID) async -> Bool {
        (try? await sdkSynchronizer.isSyncRequiredBeforeNextMigrationTransfer(accountUUID)) ?? false
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

    private func pushStateIfChanged(_ state: MigrationState, for accountUUID: AccountUUID) {
        let subject = subject(for: accountUUID)
        if subject.value != state {
            subject.send(state)
        }
    }
}

// MARK: - Pure derivations (table-testable, no SDK dependency)

/// Pure mappings from SDK-observed migration state (plus a handful of app-side flags) onto what
/// the UI shows. Every function here is a straight table lookup — no dates, no I/O, no SDK types
/// beyond the value models already `Equatable`/`Sendable` (`MigrationState`, `MigrationProgress`,
/// `MigrationAttentionReason`, `MigrationTransferRow`) — so `MigrationManagerTests` can exercise
/// every row directly.
enum MigrationDerivations {
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
}

// MARK: - Persistence + 10-minute sync<->send gate

/// `UserDefaults`-backed persistence for every app-owned migration flag, plus the 10-minute
/// sync<->send gate math. Every method that depends on "now" takes it as a parameter — never
/// reads `Date()` internally — so tests can drive the clock explicitly. Injectable
/// `UserDefaults` (default `.standard`) lets tests use an isolated named suite.
final class MigrationGateStorage: @unchecked Sendable {
    /// MOB-1496: the SDK's `MigrationNetworkPrivacyOptions` isn't `Codable` (it carries a
    /// `LightWalletEndpoint`, materialized at read time from the app's current sync endpoint —
    /// see `MigrationManagerImpl.networkPrivacyOptions()`), so only the persisted `useTor` choice
    /// is stored here, under the SAME UserDefaults key/JSON shape as before (minimally migrated:
    /// the old payload also carried a now-dropped `submissionEndpoint: String?`).
    private struct PersistedNetworkPrivacyOptions: Codable {
        var useTor: Bool
    }

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

    /// MOB-1496 Interim: only `useTor` is persisted — see `PersistedNetworkPrivacyOptions`'s doc.
    /// `MigrationManagerImpl.networkPrivacyOptions()` combines this with the app's current sync
    /// endpoint to build the SDK's `MigrationNetworkPrivacyOptions`.
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
    /// privacy, complete-acknowledged, dust-locked, last-broadcast. Backs the migration SDK
    /// simulator's debug panel "Reset app migration flags" control (MOB-1480). Deliberately leaves
    /// `migrationSyncGateUntil`/the transient sync-required flag alone: the 10-minute send gate is
    /// a short-lived timing window, not a durable app flag, and expires on its own.
    func resetPersistedFlags() {
        userDefaults.removeObject(forKey: .migrationMode)
        userDefaults.removeObject(forKey: .migrationManualDelivery)
        userDefaults.removeObject(forKey: .migrationNetworkPrivacyOptions)
        userDefaults.removeObject(forKey: .migrationCompleteAcknowledged)
        userDefaults.removeObject(forKey: .migrationDustLocked)
        userDefaults.removeObject(forKey: .migrationLastBroadcastAt)
    }
}
