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
    var reentryRoute: @Sendable () -> MigrationReentryRoute = { .entry }
    // MOB-1483: "Ironwood (NU6.3) activated on the current network" — gates `bannerVariant`,
    // `reentryRoute`, and `reconcile()`. Defaults closed so a test that doesn't override it stays
    // fail-safe instead of trapping via the macro's `unimplemented`.
    var isIronwoodActivated: @Sendable () -> Bool = { false }
    var orchardBalanceToMigrate: @Sendable (_ accountUUID: AccountUUID?) async -> Zatoshi = { _ in .zero }
    // Persistence (UserDefaults-backed; keys in SharedStateKeys.swift)
    var migrationMode: @Sendable () -> MigrationMode?
    var setMigrationMode: @Sendable (MigrationMode) -> Void
    var isManualDelivery: @Sendable () -> Bool = { false }
    var setManualDelivery: @Sendable (Bool) -> Void
    var networkPrivacyOptions: @Sendable () -> NetworkPrivacyOptions = { NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil) }
    var setNetworkPrivacyOptions: @Sendable (NetworkPrivacyOptions) -> Void
    var isCompleteAcknowledged: @Sendable () -> Bool = { false }
    var acknowledgeComplete: @Sendable () -> Void
    // 10-minute sync<->send gate
    var sendGate: @Sendable () -> MigrationSendGate = { .allowed }
    var recordMigrationBroadcast: @Sendable () -> Void
    var isSyncDeferredAfterBroadcast: @Sendable () -> Bool = { false }   // consumed by MOB-1467
    // Reconciliation
    var reconcile: @Sendable () -> Void
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
