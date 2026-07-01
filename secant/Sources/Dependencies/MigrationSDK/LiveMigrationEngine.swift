//
//  LiveMigrationEngine.swift
//  zodl
//
//  Live (SDK-backed) implementation of the Orchard → Ironwood migration, parallel to
//  `DummyMigrationEngine`. It bridges the five mismatches between the app's `MigrationSDKClient`
//  (sync getters, non-throwing, key-hiding, app `Zatoshi`-based types) and the SDK's async-throws,
//  account+key, `UInt64`-based migration API:
//
//  1. Sync getters are served from a lock-guarded cache that an async `refresh()` loop keeps in sync
//     with the SDK (on init, after every mutating call, and on a timer).
//  2. The app closures don't throw; SDK errors are caught, logged, and folded into sensible fallbacks
//     (last-known state for getters, `.networkError(retryable:)` for broadcasts, empty schedule).
//  3. App ↔ SDK types are converted at the boundary via `MigrationTypeMapping` (`.sdk` / `.app`).
//  4. Account + spending-key sourcing is hidden behind the `Gateway`; the live gateway (built in
//     `MigrationSDKLiveKey`) derives the `UnifiedSpendingKey` internally exactly as the Send flow does,
//     so neither the engine nor its tests ever handle a key.
//  5. Prototype-only surface (mode, completion-ack) is persisted app-side via `MigrationStateStore`;
//     the MigrationDebug controls become no-ops in `MigrationSDKLiveKey`.
//
//  Thread-safety: the cache is guarded by an unfair lock and the state subject is internally
//  synchronized, so the type is `@unchecked Sendable` (mirrors `DummyMigrationEngine`).
//

import Foundation
import os
@preconcurrency import Combine
@preconcurrency import ZcashLightClientKit

final class LiveMigrationEngine: @unchecked Sendable {
    /// All SDK + account access the engine needs, behind `@Sendable` closures. The `.live` gateway
    /// (in `MigrationSDKLiveKey`) wires each to `@Dependency(\.sdkSynchronizer)` plus the Send-flow
    /// account/USK sourcing; tests inject a fake. The two signing calls (`submitNoteSplit`,
    /// `signAndStore`) take no key — the live gateway derives the `UnifiedSpendingKey` internally.
    struct Gateway: Sendable {
        var currentAccountID: @Sendable () async -> AccountUUID?
        var orchardBalance: @Sendable (AccountUUID) async throws -> Zatoshi
        var state: @Sendable (AccountUUID) async throws -> ZcashLightClientKit.MigrationState
        var progress: @Sendable (AccountUUID) async throws -> ZcashLightClientKit.MigrationProgress?
        var isNoteSplitNeeded: @Sendable (AccountUUID) async throws -> Bool
        var prepareNoteSplit: @Sendable (AccountUUID) async throws -> ZcashLightClientKit.NoteSplitProposal
        var submitNoteSplit: @Sendable (
            ZcashLightClientKit.NoteSplitProposal,
            ZcashLightClientKit.NetworkPrivacyOptions,
            AccountUUID
        ) async throws -> ZcashLightClientKit.TransferResult
        var proposeTransfers: @Sendable (AccountUUID) async throws -> ZcashLightClientKit.MigrationSchedule
        var signAndStore: @Sendable (ZcashLightClientKit.MigrationSchedule, AccountUUID) async throws -> Void
        var isSyncRequiredBeforeNextTransfer: @Sendable (AccountUUID) async throws -> Bool
        var executeNext: @Sendable (
            ZcashLightClientKit.NetworkPrivacyOptions,
            AccountUUID
        ) async throws -> ZcashLightClientKit.TransferResult?
        var hasOverdueTransfers: @Sendable (AccountUUID) async throws -> Bool
        var hasInvalidTransfers: @Sendable (AccountUUID) async throws -> Bool
        var restartCurrentStep: @Sendable (AccountUUID) async throws -> ZcashLightClientKit.MigrationSchedule
        /// Re-anchors/re-proves/re-signs the active run's stale transfers; returns how many were
        /// refreshed. Takes no key — the live gateway derives the `UnifiedSpendingKey` internally.
        var refreshStale: @Sendable (AccountUUID) async throws -> UInt32
        var initializePostUpgrade: @Sendable (AccountUUID) async throws -> Void
    }

    /// The cached snapshot serving the synchronous getters. SDK-derived fields are refreshed by
    /// `refresh()`; `schedule` is set by propose/sign/restart; `mode`/`completionAcknowledged` are
    /// app-only and persisted to `MigrationStateStore`.
    private struct Cache {
        var state: MigrationState = .notStarted
        var progress: MigrationProgress?
        var noteSplitNeeded = false
        var syncRequired = false
        var overdue = false
        var invalid = false
        var orchard: Zatoshi = .zero
        var schedule: MigrationSchedule?
        var mode: MigrationMode = .privateScheduled
        var completionAcknowledged = false
    }

    /// The SDK-derived fields computed by one `refresh()` pass before being applied atomically.
    private struct SDKFields {
        var state: MigrationState
        var progress: MigrationProgress?
        var noteSplitNeeded: Bool
        var syncRequired: Bool
        var overdue: Bool
        var invalid: Bool
        var orchard: Zatoshi

        init(from cache: Cache) {
            state = cache.state
            progress = cache.progress
            noteSplitNeeded = cache.noteSplitNeeded
            syncRequired = cache.syncRequired
            overdue = cache.overdue
            invalid = cache.invalid
            orchard = cache.orchard
        }
    }

    private enum Const {
        /// ~6h between scheduled transfers (one 288-block bucket), used to estimate per-row "in Xh".
        static let hoursPerTransfer = 6
    }

    private let store: MigrationStateStore
    private let gateway: Gateway
    private let refreshInterval: Duration
    private let protected: OSAllocatedUnfairLock<Cache>
    private let stateSubject: CurrentValueSubject<MigrationState, Never>
    private let logger = Logger(subsystem: "zodl.migration", category: "LiveMigrationEngine")
    private var refreshTask: Task<Void, Never>?

    init(
        store: MigrationStateStore,
        gateway: Gateway,
        refreshInterval: Duration = .seconds(15),
        startRefreshLoop: Bool = true
    ) {
        self.store = store
        self.gateway = gateway
        self.refreshInterval = refreshInterval

        let persisted = store.load()
        var initial = Cache()
        initial.mode = persisted.mode
        initial.completionAcknowledged = persisted.completionAcknowledged

        self.protected = OSAllocatedUnfairLock(initialState: initial)
        self.stateSubject = CurrentValueSubject<MigrationState, Never>(initial.state)

        if startRefreshLoop {
            startRefreshing()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - Lock helpers

    private func read<T>(_ body: (Cache) -> T) -> T {
        protected.withLockUnchecked { body($0) }
    }

    // MARK: - Synchronous getters (served from cache)

    func currentState() -> MigrationState { read { $0.state } }

    func statePublisher() -> AnyPublisher<MigrationState, Never> { stateSubject.eraseToAnyPublisher() }

    func progress() -> MigrationProgress? { read { $0.progress } }

    func noteSplitNeeded() -> Bool { read { $0.noteSplitNeeded } }

    func syncRequiredBeforeNext() -> Bool { read { $0.syncRequired } }

    func overdue() -> Bool { read { $0.overdue } }

    func invalid() -> Bool { read { $0.invalid } }

    func orchardBalance() -> Zatoshi { read { $0.orchard } }

    func isCompletionAcknowledged() -> Bool { read { $0.completionAcknowledged } }

    func summary() -> MigrationSummary {
        read { cache in
            let transfers = cache.schedule?.transfers ?? []
            let total = cache.schedule?.transfers.count ?? (cache.progress?.totalTransfers ?? 0)
            let sent = cache.progress?.completedTransfers ?? 0
            let transferred = transfers.prefix(sent).reduce(Int64(0)) { $0 + $1.amount.amount }
            return MigrationSummary(
                transferred: Zatoshi(transferred),
                dust: cache.orchard,
                transfersSent: sent,
                transfersTotal: total,
                estimatedDurationHours: cache.schedule?.estimatedDurationHours ?? 0
            )
        }
    }

    func transferRows() -> [MigrationTransferRow] {
        read { cache in
            guard let schedule = cache.schedule else { return [] }
            let completed = cache.progress?.completedTransfers ?? 0
            return schedule.transfers.enumerated().map { index, transfer in
                let status: MigrationTransferRow.Status
                var hours = 0
                if index < completed {
                    status = .sent
                } else if index == completed {
                    // The next transfer to broadcast.
                    if cache.invalid {
                        status = .invalid
                    } else if cache.overdue {
                        status = .overdue
                    } else {
                        status = .active
                    }
                } else {
                    status = .pending
                    hours = max(0, index - completed) * Const.hoursPerTransfer
                }
                return MigrationTransferRow(
                    id: transfer.id,
                    index: index,
                    amount: transfer.amount,
                    status: status,
                    hoursFromNow: hours
                )
            }
        }
    }

    /// PROTOTYPE diagnostics: a human-readable dump of the live cache, surfaced by the MigrationDebug
    /// panel (whose simulation controls are inert against real funds). Chiefly lets us confirm whether
    /// the SDK is reporting a non-zero **Orchard** balance — the SmartBanner's migration-offer trigger,
    /// which the normal UI hides by folding every shielded pool into one total.
    func liveSnapshotDescription() -> String {
        read { cache in
            """
            Live migration engine (real funds)
            state: \(cache.state)
            orchard spendable: \(cache.orchard.amount) zats (offer shows when > 0)
            noteSplitNeeded: \(cache.noteSplitNeeded)
            syncRequired: \(cache.syncRequired)
            overdue: \(cache.overdue)   invalid: \(cache.invalid)
            """
        }
    }

    // MARK: - Mutating operations

    func prepareSplit() async -> NoteSplitProposal {
        guard let account = await gateway.currentAccountID() else { return Self.emptyProposal }
        do {
            return try await gateway.prepareNoteSplit(account).app
        } catch {
            logFailure("prepareNoteSplit", error)
            return Self.emptyProposal
        }
    }

    func submitSplit(_ proposal: NoteSplitProposal) async -> TransferResult {
        guard let account = await gateway.currentAccountID() else {
            logSkipped("submitNoteSplit")
            return TransferResult.networkError(retryable: true)
        }
        do {
            let result = try await gateway.submitNoteSplit(proposal.sdk, Self.defaultPrivacyOptions.sdk, account)
            await refresh()
            return result.app
        } catch {
            logFailure("submitNoteSplit", error)
            return TransferResult.networkError(retryable: true)
        }
    }

    func propose() async -> MigrationSchedule {
        guard let account = await gateway.currentAccountID() else { return Self.emptySchedule }
        do {
            let schedule = try await gateway.proposeTransfers(account).app
            setSchedule(schedule)
            return schedule
        } catch {
            logFailure("proposeMigrationTransfers", error)
            return Self.emptySchedule
        }
    }

    func signAndStore(_ schedule: MigrationSchedule) async {
        guard let account = await gateway.currentAccountID() else {
            logSkipped("signAndStoreMigrationSchedule")
            return
        }
        do {
            try await gateway.signAndStore(schedule.sdk, account)
            setSchedule(schedule)
            await refresh()
        } catch {
            logFailure("signAndStoreMigrationSchedule", error)
        }
    }

    func executeNext(_ options: NetworkPrivacyOptions) async -> TransferResult? {
        guard let account = await gateway.currentAccountID() else {
            logSkipped("executeNextPendingTransfer")
            return TransferResult.networkError(retryable: true)
        }
        do {
            let result = try await gateway.executeNext(options.sdk, account)
            await refresh()
            return result?.app
        } catch {
            logFailure("executeNextPendingTransfer", error)
            return TransferResult.networkError(retryable: true)
        }
    }

    func restart() async -> MigrationSchedule {
        guard let account = await gateway.currentAccountID() else { return Self.emptySchedule }
        do {
            let schedule = try await gateway.restartCurrentStep(account).app
            setSchedule(schedule)
            await refresh()
            return schedule
        } catch {
            logFailure("restartCurrentMigrationStep", error)
            return Self.emptySchedule
        }
    }

    /// Stalled/overdue recovery: re-anchor/re-prove/re-sign the scheduled transfers via the SDK's
    /// `refreshStaleTransfers`. Lighter than `restart()` (which re-proposes a whole new schedule). The
    /// refreshed count is logged for observability; the UI's reschedule action needs no return value.
    func rescheduleStalled() async {
        guard let account = await gateway.currentAccountID() else {
            logSkipped("refreshStaleTransfers")
            return
        }
        do {
            let refreshed = try await gateway.refreshStale(account)
            logger.info("Migration refreshStaleTransfers refreshed \(refreshed, privacy: .public) transfer(s).")
            await refresh()
        } catch {
            logFailure("refreshStaleTransfers", error)
        }
    }

    /// Invalid-note recovery: the SDK has no lighter primitive, so re-propose the current step.
    func recreateInvalid() async { _ = await restart() }

    func initializePostUpgrade() {
        Task { [weak self] in
            guard let self, let account = await self.gateway.currentAccountID() else { return }
            do {
                try await self.gateway.initializePostUpgrade(account)
            } catch {
                self.logFailure("initializePostUpgrade", error)
            }
            await self.refresh()
        }
    }

    // MARK: - App-side state (persisted via MigrationStateStore)

    func selectMode(_ mode: MigrationMode) {
        protected.withLockUnchecked { $0.mode = mode }
        persistAppState()
    }

    func acknowledgeCompletion() {
        let state = protected.withLockUnchecked { cache -> MigrationState in
            cache.completionAcknowledged = true
            return cache.state
        }
        persistAppState()
        // Re-emit the current state so the Home SmartBanner re-evaluates and drops the completion banner.
        stateSubject.send(state)
    }

    // MARK: - Refresh

    /// Pulls the live SDK state into the cache. Each SDK call is independent: a failure logs and keeps
    /// the last-known value for that field. Emits on the state subject only when the state changes.
    func refresh() async {
        guard let account = await gateway.currentAccountID() else { return }

        var fields = read { SDKFields(from: $0) }

        do {
            fields.state = try await gateway.state(account).app
        } catch {
            logFailure("migrationState", error)
        }
        do {
            fields.progress = try await gateway.progress(account)?.app
        } catch {
            logFailure("migrationProgress", error)
        }
        do {
            fields.noteSplitNeeded = try await gateway.isNoteSplitNeeded(account)
        } catch {
            logFailure("isNoteSplitNeeded", error)
        }
        do {
            fields.syncRequired = try await gateway.isSyncRequiredBeforeNextTransfer(account)
        } catch {
            logFailure("isSyncRequiredBeforeNextTransfer", error)
        }
        do {
            fields.overdue = try await gateway.hasOverdueTransfers(account)
        } catch {
            logFailure("hasOverdueTransfers", error)
        }
        do {
            fields.invalid = try await gateway.hasInvalidTransfers(account)
        } catch {
            logFailure("hasInvalidTransfers", error)
        }
        do {
            fields.orchard = try await gateway.orchardBalance(account)
        } catch {
            logFailure("orchardBalance", error)
        }

        apply(fields)
    }

    // MARK: - Private

    private func apply(_ fields: SDKFields) {
        let shouldEmit = protected.withLockUnchecked { cache -> Bool in
            let stateChanged = cache.state != fields.state
            // The Home SmartBanner offers migration when `orchard > 0` while the state is still
            // `.notStarted`, and it re-evaluates only on a `statePublisher()` emission. A wallet
            // finishing sync moves the Orchard balance 0 -> positive with NO migration-state change,
            // so emit on that threshold crossing too — otherwise the offer never appears (the banner
            // subscribed while the balance was still zero and the state never leaves `.notStarted`).
            // Gate on the `orchard > 0` predicate, not every balance delta, so the in-progress
            // migration screens that also observe this stream aren't churned; both migration-flow
            // consumers are idempotent to a repeated state value.
            let offerAvailabilityChanged = (cache.orchard.amount > 0) != (fields.orchard.amount > 0)
            cache.state = fields.state
            cache.progress = fields.progress
            cache.noteSplitNeeded = fields.noteSplitNeeded
            cache.syncRequired = fields.syncRequired
            cache.overdue = fields.overdue
            cache.invalid = fields.invalid
            cache.orchard = fields.orchard
            return stateChanged || offerAvailabilityChanged
        }
        if shouldEmit {
            stateSubject.send(fields.state)
        }
    }

    private func setSchedule(_ schedule: MigrationSchedule) {
        protected.withLockUnchecked { $0.schedule = schedule }
    }

    private func persistAppState() {
        let (mode, acknowledged) = protected.withLockUnchecked { ($0.mode, $0.completionAcknowledged) }
        var snapshot = store.load()
        snapshot.mode = mode
        snapshot.completionAcknowledged = acknowledged
        store.save(snapshot)
    }

    private func startRefreshing() {
        let interval = refreshInterval
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.refresh()
            }
        }
    }

    private func logFailure(_ operation: String, _ error: Error) {
        logger.error("Migration \(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
    }

    private func logSkipped(_ operation: String) {
        logger.warning("Migration \(operation, privacy: .public) skipped: no active wallet account.")
    }

    private static let emptyProposal = NoteSplitProposal(outputNotes: [], fee: .zero)
    private static let emptySchedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
    /// `submitNoteSplit` carries no privacy options from the UI; the SDK ignores them in v1 anyway.
    private static let defaultPrivacyOptions = NetworkPrivacyOptions(useTor: false)
}
