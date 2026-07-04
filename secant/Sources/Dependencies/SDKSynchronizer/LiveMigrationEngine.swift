//
//  LiveMigrationEngine.swift
//  zodl
//
//  Live (SDK-backed) implementation of the Orchard -> Ironwood migration members on
//  `SDKSynchronizerClient` (Dependencies/SDKSynchronizer/SDKSynchronizerInterface.swift). It bridges
//  the mismatches between those members (sync getters, non-throwing, app `Zatoshi`-based types) and
//  the SDK's async-throws, per-account, `UInt64`-based migration API (Synchronizer's
//  "MARK: - Ironwood migration" section):
//
//  1. Sync getters are served from a lock-guarded cache that an async `refresh()` loop keeps in sync
//     with the SDK (on init, after every mutating call, and on a timer).
//  2. The client's closures don't throw; SDK errors are caught, logged, and folded into sensible
//     fallbacks (last-known state for getters, `.networkError(retryable:)` for broadcasts, empty
//     schedule for proposals).
//  3. App <-> SDK types are converted at the boundary via `MigrationTypeMapping` (`.sdk` / `.app`).
//  4. Account + spending-key sourcing is hidden behind the `Gateway`; the live gateway (built in
//     `SDKSynchronizerLive`) derives the `UnifiedSpendingKey` internally exactly as the Send flow
//     does, so neither the engine nor its tests ever handle a key.
//  5. The SDK has no `AttentionReason` case for a stalled-but-not-yet-invalid transfer, so the engine
//     synthesizes the app-only `.requiresAttention(.transferStalled)` state from `.inProgress` +
//     `hasOverdueTransfers` — see `synthesizeAppState(from:overdue:)`, the single place this happens.
//  6. The user's chosen `MigrationMode` and the committed transfer schedule are app-side state with
//     no SDK counterpart; both are persisted via `MigrationScheduleStore` so they survive a relaunch
//     (mode drives routing; the schedule rows let the status screen rehydrate before the first
//     `refresh()` completes).
//
//  Thread-safety: the cache is guarded by an unfair lock and the state subject is internally
//  synchronized, so the type is `@unchecked Sendable`.
//

import Foundation
import os
@preconcurrency import Combine
@preconcurrency import ZcashLightClientKit

final class LiveMigrationEngine: @unchecked Sendable {
    /// All SDK + account access the engine needs, behind `@Sendable` closures. The `.live` gateway
    /// (in `SDKSynchronizerLive`) wires each to the `synchronizer` instance plus the Send-flow
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
        var proposeImmediateTransfers: @Sendable (AccountUUID) async throws -> ZcashLightClientKit.MigrationSchedule
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
        // Keystone (PCZT) external-signer path (MOB-1469 P4). The SDK returns proof-less unsigned
        // PCZTs and keeps the proven originals staged internally — never add proofs app-side.
        var proposeNoteSplitPCZT: @Sendable (AccountUUID) async throws -> Pczt
        var proposeTransferPCZTs: @Sendable (
            ZcashLightClientKit.MigrationSchedule,
            AccountUUID
        ) async throws -> [ZcashLightClientKit.MigrationTransferPCZT]
        var storeSignedTransferPCZTs: @Sendable ([ZcashLightClientKit.MigrationTransferPCZT], AccountUUID) async throws -> Void
        var submitSignedNoteSplitPCZT: @Sendable (Pczt, AccountUUID) async throws -> ZcashLightClientKit.TransferResult
        /// Strips the PCZT down to what the signing device needs (the send flow's
        /// `redactPCZTForSigner`) — run on every proposed PCZT before it reaches a QR encoder.
        var redactPCZT: @Sendable (Pczt) async throws -> Pczt
    }

    /// The cached snapshot serving the synchronous getters. SDK-derived fields are refreshed by
    /// `refresh()`; `schedule` is set by propose/sign/restart; `mode` is app-only and persisted to
    /// `MigrationScheduleStore`.
    private struct Cache {
        var sdkState: MigrationState = .notStarted
        var progress: MigrationProgress?
        var noteSplitNeeded = false
        var syncRequired = false
        var overdue = false
        var invalid = false
        var orchard: Zatoshi = .zero
        var schedule: MigrationSchedule?
        var mode: MigrationMode = .privateScheduled
        /// Keystone (PCZT) session pairing: the transfer ids from the last `proposeTransferPCZTs`
        /// call, in proposal order. The signed PCZTs come back positionally (session i signs the
        /// i-th proposed PCZT), so `storeSignedTransferPCZTs` re-pairs them by zipping this order
        /// with the signed array — cleared only once a store succeeds.
        var pendingTransferPCZTIds: [String] = []
        /// The schedule those PCZTs were built from — persisted as pending rows (like
        /// `signAndStore`) once the signed set stores.
        var pendingTransferPCZTSchedule: MigrationSchedule?

        /// The app-facing state after stall synthesis — see `LiveMigrationEngine.synthesizeAppState`.
        var appState: MigrationState { LiveMigrationEngine.synthesizeAppState(from: sdkState, overdue: overdue) }
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
            state = cache.sdkState
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

    private let store: MigrationScheduleStore
    private let gateway: Gateway
    private let refreshInterval: Duration
    private let protected: OSAllocatedUnfairLock<Cache>
    private let stateSubject: CurrentValueSubject<MigrationState, Never>
    private let logger = Logger(subsystem: "zodl.migration", category: "LiveMigrationEngine")
    private var refreshTask: Task<Void, Never>?

    init(
        store: MigrationScheduleStore,
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
        // Rehydrate the committed schedule so a relaunch mid-migration still renders the transfer
        // rows (progress/totals come live from the SDK either way; without this the status screen
        // would show "0 of N" with an empty list after every restart).
        if !persisted.transfers.isEmpty {
            initial.schedule = MigrationSchedule(
                transfers: persisted.transfers.map(\.proposal),
                estimatedDurationHours: persisted.scheduleDurationHours ?? 0
            )
        }

        self.protected = OSAllocatedUnfairLock(initialState: initial)
        self.stateSubject = CurrentValueSubject<MigrationState, Never>(initial.appState)

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

    func currentState() -> MigrationState { read { $0.appState } }

    func statePublisher() -> AnyPublisher<MigrationState, Never> { stateSubject.eraseToAnyPublisher() }

    func progress() -> MigrationProgress? { read { $0.progress } }

    /// Gated on `mode`: a note split only makes sense on the private/scheduled path (the immediate
    /// path sweeps the whole balance in one transfer and never denominates). `selectMode(_:)` must be
    /// called before this is read for the gate to reflect the user's actual choice.
    func noteSplitNeeded() -> Bool { read { $0.mode == .privateScheduled && $0.noteSplitNeeded } }

    func syncRequiredBeforeNext() -> Bool { read { $0.syncRequired } }

    func overdue() -> Bool { read { $0.overdue } }

    func invalid() -> Bool { read { $0.invalid } }

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

    // MARK: - Keystone (PCZT) external-signer path (MOB-1469 P4)

    /// The note-split transaction as a REDACTED, QR-ready PCZT for the signing device. The SDK
    /// stages the proven original internally; redaction happens here so the member's contract is
    /// "feed the result straight to `urEncoderForPCZT`". An empty `Pczt` signals failure — the
    /// coordinator treats it as "nothing to sign" and never starts a session.
    func proposeNoteSplitPCZT() async -> Pczt {
        guard let account = await gateway.currentAccountID() else {
            logSkipped("proposeNoteSplitPCZT")
            return Pczt()
        }
        do {
            let pczt = try await gateway.proposeNoteSplitPCZT(account)
            return try await gateway.redactPCZT(pczt)
        } catch {
            logFailure("proposeNoteSplitPCZT", error)
            return Pczt()
        }
    }

    /// One REDACTED, QR-ready PCZT per transfer of the confirmed `schedule`, in proposal order.
    /// Caches the transfer-id order (and the schedule) for `storeSignedTransferPCZTs`: the signed
    /// PCZTs handed back later pair with these ids BY INDEX, so callers must preserve the order.
    /// An empty array signals failure — the coordinator never starts a session.
    func proposeTransferPCZTs(_ schedule: MigrationSchedule) async -> [Pczt] {
        guard let account = await gateway.currentAccountID() else {
            logSkipped("proposeMigrationTransferPCZTs")
            return []
        }
        do {
            let pairs = try await gateway.proposeTransferPCZTs(schedule.sdk, account)
            var redacted: [Pczt] = []
            redacted.reserveCapacity(pairs.count)
            for pair in pairs {
                redacted.append(try await gateway.redactPCZT(pair.pczt))
            }
            protected.withLockUnchecked {
                $0.pendingTransferPCZTIds = pairs.map(\.id)
                $0.pendingTransferPCZTSchedule = schedule
            }
            return redacted
        } catch {
            logFailure("proposeMigrationTransferPCZTs", error)
            return []
        }
    }

    /// Stores the full signed set — all-or-nothing. Rebuilds the id↔PCZT pairs by zipping the
    /// cached `proposeTransferPCZTs` id order with `signed` (same order, same count); a count
    /// mismatch or missing cache stores nothing (the invariant the SDK enforces crate-side too).
    /// On success the schedule rows persist as pending exactly like `signAndStore`; on a thrown
    /// store nothing was stored — the cache is kept so the whole set can be retried.
    func storeSignedTransferPCZTs(_ signed: [Pczt]) async {
        guard let account = await gateway.currentAccountID() else {
            logSkipped("storeSignedMigrationTransferPCZTs")
            return
        }
        let (ids, schedule) = read { ($0.pendingTransferPCZTIds, $0.pendingTransferPCZTSchedule) }
        guard !ids.isEmpty, ids.count == signed.count else {
            logger.error(
                "Migration signed-PCZT store skipped: \(signed.count, privacy: .public) signed vs \(ids.count, privacy: .public) cached ids."
            )
            return
        }
        let pairs = zip(ids, signed).map { ZcashLightClientKit.MigrationTransferPCZT(id: $0, pczt: $1) }
        do {
            try await gateway.storeSignedTransferPCZTs(pairs, account)
            protected.withLockUnchecked {
                $0.pendingTransferPCZTIds = []
                $0.pendingTransferPCZTSchedule = nil
            }
            if let schedule {
                setSchedule(schedule)
            }
            await refresh()
        } catch {
            // All-or-nothing: nothing was stored, the staged originals persist SDK-side and the
            // cached pairing persists here, so the flow may retry with the same signed set.
            logFailure("storeSignedMigrationTransferPCZTs", error)
        }
    }

    /// Stores + broadcasts the device-signed note-split PCZT (the external-signer counterpart of
    /// `submitSplit`). Retryable with the SAME signed PCZT — the SDK re-broadcasts the stored prep
    /// transaction without double-storing.
    func submitSignedNoteSplit(_ pczt: Pczt) async -> TransferResult {
        guard let account = await gateway.currentAccountID() else {
            logSkipped("submitSignedNoteSplitPCZT")
            return TransferResult.networkError(retryable: true)
        }
        do {
            let result = try await gateway.submitSignedNoteSplitPCZT(pczt, account)
            await refresh()
            return result.app
        } catch {
            logFailure("submitSignedNoteSplitPCZT", error)
            return TransferResult.networkError(retryable: true)
        }
    }

    /// Routes by the persisted `mode` (recorded via `selectMode(_:)` before this is called):
    /// `.immediate` sweeps the whole spendable Orchard balance in one transfer via the SDK's
    /// immediate-path proposal; `.privateScheduled` uses the regular denominated schedule.
    func propose() async -> MigrationSchedule {
        guard let account = await gateway.currentAccountID() else { return Self.emptySchedule }
        let mode = read { $0.mode }
        do {
            let schedule: MigrationSchedule
            switch mode {
            case .immediate:
                schedule = try await gateway.proposeImmediateTransfers(account).app
            case .privateScheduled:
                schedule = try await gateway.proposeTransfers(account).app
            }
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
            if case .success(let txId) = result?.app {
                advanceFirstPendingTransfer(toSent: txId)
            }
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

    /// Invalid-note recovery: the SDK has no lighter primitive, so re-propose the current step (the
    /// Recovery screen's "recreate" action re-proposes the remainder of the schedule under the hood).
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

    // MARK: - App-side state (persisted via MigrationScheduleStore)

    /// Recorded before `proposeMigrationTransfers()`/`isNoteSplitNeeded()` are next read, so both the
    /// propose-routing and the split gate reflect the user's choice; persisted so it survives relaunch.
    func selectMode(_ mode: MigrationMode) {
        protected.withLockUnchecked { $0.mode = mode }
        persistAppState()
    }

    // MARK: - Refresh

    /// Pulls the live SDK state into the cache. Each SDK call is independent: a failure logs and keeps
    /// the last-known value for that field. Emits on the state subject only when the app-facing
    /// (post-synthesis) state changes, or when the `orchardBalance > 0` predicate toggles.
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

    /// Synthesizes the app-facing `.requiresAttention(.transferStalled)` state from the SDK's plain
    /// `.inProgress` plus the independently-read `hasOverdueTransfers` flag. The SDK's `AttentionReason`
    /// has no stalled case (`invalidTransfer`/`transferExpired`/`syncRequiredBeforeNext` only, see
    /// `ZcashLightClientKit.AttentionReason`) — this is the one place the app-only
    /// `AttentionReason.transferStalled` case is produced, so every banner/re-entry/status consumer
    /// downstream sees a single, already-synthesized state and needs no overdue-awareness of its own.
    private static func synthesizeAppState(from sdkState: MigrationState, overdue: Bool) -> MigrationState {
        guard case .inProgress(let progress) = sdkState, overdue else { return sdkState }
        return MigrationState.requiresAttention(
            AttentionReason.transferStalled(transferNumber: progress.completedTransfers + 1)
        )
    }

    private func apply(_ fields: SDKFields) {
        let shouldEmit = protected.withLockUnchecked { cache -> Bool in
            let beforeAppState = cache.appState
            let afterAppState = Self.synthesizeAppState(from: fields.state, overdue: fields.overdue)
            let stateChanged = beforeAppState != afterAppState
            // The Home SmartBanner offers migration when `orchard > 0` while the state is still
            // `.notStarted`, and it re-evaluates only on a `statePublisher()` emission. A wallet
            // finishing sync moves the Orchard balance 0 -> positive with NO migration-state change,
            // so emit on that threshold crossing too — otherwise the offer never appears (the banner
            // subscribed while the balance was still zero and the state never leaves `.notStarted`).
            // Gate on the `orchard > 0` predicate, not every balance delta, so the in-progress
            // migration screens that also observe this stream aren't churned; both migration-flow
            // consumers are idempotent to a repeated state value.
            let offerAvailabilityChanged = (cache.orchard.amount > 0) != (fields.orchard.amount > 0)
            cache.sdkState = fields.state
            cache.progress = fields.progress
            cache.noteSplitNeeded = fields.noteSplitNeeded
            cache.syncRequired = fields.syncRequired
            cache.overdue = fields.overdue
            cache.invalid = fields.invalid
            cache.orchard = fields.orchard
            return stateChanged || offerAvailabilityChanged
        }
        if shouldEmit {
            stateSubject.send(read { $0.appState })
        }
    }

    private func setSchedule(_ schedule: MigrationSchedule) {
        protected.withLockUnchecked { $0.schedule = schedule }
        // Persist the rows so a relaunch mid-migration can rehydrate them (see init).
        var snapshot = store.load()
        snapshot.transfers = schedule.transfers.map { StoredTransfer(proposal: $0, status: .pending) }
        snapshot.scheduleDurationHours = schedule.estimatedDurationHours
        store.save(snapshot)
    }

    /// Advances the first still-pending persisted row to `.sent(txId:)` after a successful broadcast,
    /// so a relaunch between transfers still shows the correct row statuses before the next `refresh()`.
    private func advanceFirstPendingTransfer(toSent txId: String) {
        var snapshot = store.load()
        guard let index = snapshot.transfers.firstIndex(where: { $0.status == .pending }) else { return }
        snapshot.transfers[index].status = .sent(txId: txId)
        store.save(snapshot)
    }

    private func persistAppState() {
        let mode = read { $0.mode }
        var snapshot = store.load()
        snapshot.mode = mode
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
        // `ZcashError.localizedDescription` is the generic "ZRUSTxxxx: ..." string and drops the
        // associated rust-layer detail. `String(describing:)` on the enum includes that associated
        // value — the real FFI error (e.g. "sign_and_store_migration_schedule: orchard proof: ...") —
        // which is what actually pinpoints a proving / PCZT / anchor failure.
        logger.error(
            "Migration \(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)"
        )
    }

    private func logSkipped(_ operation: String) {
        logger.warning("Migration \(operation, privacy: .public) skipped: no active wallet account.")
    }

    private static let emptyProposal = NoteSplitProposal(outputNotes: [], fee: .zero)
    private static let emptySchedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
    /// `submitNoteSplit` carries no privacy options from the UI; the SDK ignores them in v1 anyway.
    private static let defaultPrivacyOptions = NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil)
}
