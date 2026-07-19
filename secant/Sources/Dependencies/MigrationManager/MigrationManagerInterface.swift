//
//  MigrationManagerInterface.swift
//  Zashi
//
//  App-owned logic for the Orchard -> Ironwood migration (MOB-1466): persistence, the
//  sync<->send privacy gate's app-owned half (MOB-1496 W3 — see `sendGate` below), and the
//  banner-variant / re-entry-route derivations. The SDK only exposes raw state (`MigrationState`,
//  `MigrationProgress`, …) — this client is the single place that turns that state plus app-side
//  flags into what the UI actually shows.
//

import Foundation
@preconcurrency import Combine
@preconcurrency import ZcashLightClientKit
import ComposableArchitecture

extension DependencyValues {
    var migrationManager: MigrationManagerClient {
        get { self[MigrationManagerClient.self] }
        set { self[MigrationManagerClient.self] = newValue }
    }
}

@DependencyClient
struct MigrationManagerClient: Sendable {
    // Derivations (pure given SDK members + persistence; unit-tested as tables)
    var bannerVariant: @Sendable (_ accountUUID: AccountUUID?) async -> MigrationBannerVariant? = { _ in nil }
    // MOB-1496: async — the SDK's per-account migration reads are now `async throws`.
    var reentryRoute: @Sendable () async -> MigrationReentryRoute = { .entry }
    // MOB-1483: "Ironwood (NU6.3) activated on the current network" — gates `bannerVariant`,
    // `reentryRoute`, and `reconcile()`. `= { false }` is a required macro default (non-Void,
    // non-throwing return), NOT a test fallback — see the `recordCommittedSchedule` note below.
    var isIronwoodActivated: @Sendable () -> Bool = { false }
    var orchardBalanceToMigrate: @Sendable (_ accountUUID: AccountUUID?) async -> Zatoshi = { _ in .zero }
    // Progress UI (MOB-1496: relocated from SDKSynchronizerClient — app-side derivations over the
    // SDK's per-account state, not raw SDK calls). `nil` accountUUID resolves the selected account
    // internally, same convention as `bannerVariant` above.
    var migrationSummary: @Sendable (_ accountUUID: AccountUUID?) async -> MigrationSummary = { _ in MigrationSummary.zero }
    var migrationTransfers: @Sendable (_ accountUUID: AccountUUID?) async -> [MigrationTransferRow] = { _ in [] }
    // Persisted committed schedule (MOB-1496 W2): the SDK retains no proposal list once a schedule
    // is committed — these persist the app's own record of it, which `migrationSummary`/
    // `migrationTransfers` above derive from. `nil` accountUUID resolves the selected account
    // internally, same convention as the other members here.
    // swift-dependencies gotcha: these no-op defaults do NOT let a test skip mocking. The client has
    // no `testValue`, so the first uncustomized `@Dependency(\.migrationManager)` access in a test
    // fails "has no test implementation" (whole-client, any member/arity — not per-endpoint).
    // Customizing ANY one member unlocks the client for that test; un-overridden members then fall
    // through to their LIVE impl, not these no-ops.
    var recordCommittedSchedule: @Sendable (_ accountUUID: AccountUUID?, _ schedule: MigrationSchedule) async -> Void = { _, _ in }
    var recordTransferBroadcast: @Sendable (_ accountUUID: AccountUUID?, _ result: MigrationTransferResult) async -> Void = { _, _ in }
    // Dust resolution (MOB-1487/MOB-1496: relocated — app persistence, not SDK calls).
    var lockMigrationDust: @Sendable () async throws -> Void
    var isMigrationDustLocked: @Sendable () -> Bool = { false }
    // Per-account migration-state stream (MOB-1496: relocated from SDKSynchronizerClient's
    // `migrationStateStream`) — emits on `reconcile()` and whenever a store reports a completed
    // migration op. `nil` accountUUID resolves the selected account internally.
    var stateEvents: @Sendable (_ accountUUID: AccountUUID?) -> AnyPublisher<MigrationState, Never> = { _ in Empty().eraseToAnyPublisher() }
    // Persistence (UserDefaults-backed; keys in SharedStateKeys.swift)
    var migrationMode: @Sendable () -> MigrationMode?
    var setMigrationMode: @Sendable (MigrationMode) -> Void
    var isManualDelivery: @Sendable () -> Bool = { false }
    var setManualDelivery: @Sendable (Bool) -> Void
    // MOB-1496 (W4): ensure-or-read the run's atomic network snapshot (Tor + sync provider/endpoint +
    // broadcast provider/endpoint — see `MigrationNetworkSnapshot`) for `accountUUID` (`nil` resolves
    // the selected account, same convention as `migrationSummary`/`migrationTransfers` above), mapped
    // onto the SDK's `MigrationNetworkPrivacyOptions`. Idempotent for the life of a run: the first
    // call creates and persists the snapshot; every later call (from ANY lane, any elapsed time)
    // returns the SAME persisted values, immune to a mid-run auto server switch. NEVER throws — every
    // internal failure degrades to SOME snapshot (see `MigrationManagerImpl.ensureNetworkSnapshot`'s
    // doc). Default is the closed/no-Tor, unset-endpoint value — the macro requires a concrete
    // default for a non-throwing, non-`Void`/non-`Optional`-returning closure; every real call site
    // resolves a live snapshot. Tests never observe this default (see the `recordCommittedSchedule`
    // note).
    var migrationNetworkOptions: @Sendable (_ accountUUID: AccountUUID?) async -> MigrationNetworkPrivacyOptions = { _ in
        MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
    }
    // MOB-1496 (W4): every persisted network snapshot across `walletAccounts` (+ the selected
    // account, defensively, deduped) — i.e. every account with a currently-active migration run.
    // Drives `AutoServerSelectionLiveKey`'s pinning (auto server selection stays within an active
    // run's sync-provider family) and `ServerSetupStore`'s manual-switch privacy warning.
    var activeNetworkSnapshots: @Sendable () -> [MigrationNetworkSnapshot] = { [] }
    // Persists the pre-run Tor choice the migration entry/Tor sheet writes. Consumed by
    // `ensureNetworkSnapshot` when a run's snapshot is first taken — a later call does NOT alter an
    // already-active run's snapshot (see `MigrationNetworkSnapshot.useTor`'s doc).
    var setNetworkPrivacyOptions: @Sendable (_ useTor: Bool) -> Void
    var isCompleteAcknowledged: @Sendable () -> Bool = { false }
    var acknowledgeComplete: @Sendable () -> Void
    // Sync<->send gate (app direction: a completed sync briefly disables migration sends). MOB-1496
    // (W3): re-keyed off observed sync completions + the SDK's own buffer duration — the OTHER
    // direction (broadcast briefly disables sync) is now enforced by the SDK itself
    // (`SDKSynchronizerClient.isMigrationSyncBlocked`/`migrationSyncBlockedStream`); this client no
    // longer duplicates it.
    var sendGate: @Sendable () async -> MigrationSendGate = { .allowed }
    // MOB-1496 (W3): written once per completed sync from Root's existing sync-completion edge
    // (`RootInitialization.swift`'s `.synchronizerStateChanged`, the same place `reconcile()` fires
    // on the false->true transition into `.upToDate`) — NOT on every tick. `= { }` mirrors
    // `reconcile`'s no-op but is not a test fallback (see the `recordCommittedSchedule` note).
    var recordSyncCompleted: @Sendable () -> Void = { }
    // Reconciliation. MOB-1496: async — re-reads `getMigrationState` for `stateEvents`; call sites in
    // `MigrationSendingStore`/`MigrationNoteSplitStore` (post-broadcast) join the launch/foreground
    // ones. `= { }` is a no-op default, not a test fallback (see the `recordCommittedSchedule` note).
    var reconcile: @Sendable () async -> Void = { }
    // Debug/testnet-only: clears every persisted migration flag this client owns (mode, manual
    // delivery, network privacy, complete-acknowledged, dust-locked) — consumed by the
    // migration SDK simulator's debug panel "Reset app migration flags" control (MOB-1480).
    var resetPersistedFlags: @Sendable () -> Void
}

enum MigrationSendGate: Equatable, Sendable {
    case allowed
    // MOB-1496 (W3): `sdkSynchronizer.isSyncing()` == true right now — CTA disabled.
    case syncRequired
    // MOB-1496 (W3): a sync completed < `migrationPrivacySyncBufferDuration()` ago — CTA disabled,
    // `Date` is when the gate clears (sync-completion timestamp + buffer).
    case waitUntil(Date)
}

enum MigrationReentryRoute: Equatable, Sendable {
    case recovery(isExpired: Bool)       // §4.3 row 1 — variant from AttentionReason (.transferExpired → true, else false)
    case statusResume                    // row 2
    case statusProgress                  // row 3
    case complete                        // row 4 (unacknowledged)
    case noteSplitProgress               // row 5
    case reviewManual(step: Int, total: Int)  // row 6 — manual delivery, next transfer due
    case entry                           // row 7 (notStarted / readyToPropose)
}
