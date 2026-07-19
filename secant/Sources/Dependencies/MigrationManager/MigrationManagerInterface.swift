//
//  MigrationManagerInterface.swift
//  Zashi
//
//  App-owned logic for the Orchard -> Ironwood migration (MOB-1466): persistence, the
//  10-minute sync<->send gate, and the banner-variant / re-entry-route derivations. The SDK
//  only exposes raw state (`MigrationState`, `MigrationProgress`, …) — this client is the
//  single place that turns that state plus app-side flags into what the UI actually shows.
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
    // `reentryRoute`, and `reconcile()`. Defaults closed so a test that doesn't override it stays
    // fail-safe instead of trapping via the macro's `unimplemented`.
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
    // internally, same convention as the other members here. Defaulted to a no-op (like
    // `reconcile` below) so a test exercising an op's success path doesn't have to mock these too.
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
    // MOB-1496 Interim: W4 replaces this with the migration network snapshot (separate broadcast
    // provider). Endpoint is materialized at read time as the app's current sync endpoint. Default
    // is the closed/no-Tor, unset-endpoint value — the macro requires a concrete default for a
    // non-throwing, non-`Void`/non-`Optional`-returning closure; every real call site resolves a
    // live endpoint, so this only surfaces if a test exercises the member without mocking it.
    var networkPrivacyOptions: @Sendable () -> MigrationNetworkPrivacyOptions = {
        MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
    }
    var setNetworkPrivacyOptions: @Sendable (_ useTor: Bool) -> Void
    var isCompleteAcknowledged: @Sendable () -> Bool = { false }
    var acknowledgeComplete: @Sendable () -> Void
    // 10-minute sync<->send gate. MOB-1496: async — `isSyncRequiredBeforeNextMigrationTransfer` is
    // now `async throws`.
    var sendGate: @Sendable () async -> MigrationSendGate = { .allowed }
    var recordMigrationBroadcast: @Sendable () -> Void
    var isSyncDeferredAfterBroadcast: @Sendable () -> Bool = { false }   // consumed by MOB-1467
    // Reconciliation. MOB-1496: async — re-reads `getMigrationState` for `stateEvents` too. Default
    // no-op (unlike most side-effecting members here, which stay `unimplemented`-by-default) since
    // MOB-1496 adds call sites in `MigrationSendingStore`/`MigrationNoteSplitStore` (post-broadcast
    // freshness) beyond the original launch/foreground-entry ones — a test exercising those success
    // paths without caring about `stateEvents` freshness shouldn't have to mock this too.
    var reconcile: @Sendable () async -> Void = { }
    // Debug/testnet-only: clears every persisted migration flag this client owns (mode, manual
    // delivery, network privacy, complete-acknowledged, last-broadcast) — consumed by the
    // migration SDK simulator's debug panel "Reset app migration flags" control (MOB-1480).
    var resetPersistedFlags: @Sendable () -> Void
}

enum MigrationSendGate: Equatable, Sendable {
    case allowed
    case syncRequired            // isSyncRequiredBeforeNextMigrationTransfer() == true — CTA disabled
    case waitUntil(Date)         // required sync finished < 10 min ago — CTA disabled with ETA
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
