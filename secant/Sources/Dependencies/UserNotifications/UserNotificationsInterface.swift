//
//  UserNotificationsInterface.swift
//  Zashi
//
//  Seam over `UNUserNotificationCenter` for the Orchard -> Ironwood migration: authorization
//  (MOB-1466's Notifications permission screen) plus local-notification scheduling (MOB-1467,
//  §4.4 matrix).
//

import UserNotifications
import ComposableArchitecture

extension DependencyValues {
    var userNotifications: UserNotificationsClient {
        get { self[UserNotificationsClient.self] }
        set { self[UserNotificationsClient.self] = newValue }
    }
}

@DependencyClient
struct UserNotificationsClient: Sendable {
    var authorizationStatus: @Sendable () async -> UNAuthorizationStatus = { .notDetermined }
    var requestAuthorization: @Sendable () async -> Bool = { false }   // .alert, .sound, .badge
    // nil date = deliver now; nil accountUUID = legacy/no-account payload (R8-T5 S4: every current
    // compose site provides one — hex-encoded, `Data.hexEncodedString()` — so a tap can open the
    // account the notification was actually for instead of always resolving `selectedWalletAccount`)
    var scheduleMigrationNotification: @Sendable (MigrationNotification, Date?, String?) async -> Void
    // pending + delivered, "migration." prefix. The hex-encoded account scope (same encoding
    // `scheduleMigrationNotification` takes) limits the sweep to THAT account's suffixed
    // identifiers plus legacy UN-suffixed ones (stale by definition under the per-account
    // scheme); `nil` sweeps every "migration." identifier — the wallet-wide wipe paths only.
    // Audit 2026-08-03 (P1): the arming loop's wallet-wide cancel erased the OTHER account's
    // just-armed poke on every per-account pass — a two-account wallet backgrounded with no
    // armed wake-up at all.
    var cancelMigrationNotifications: @Sendable (_ scopedToAccountHex: String?) async -> Void
    // delivered ONLY — pending (manual ready reminder) must survive
    var clearDeliveredMigrationNotifications: @Sendable () async -> Void
    // Debug read-back (What's New debug screen `print_notifs`): every pending "migration."
    // request mapped to the value the pure report formatter renders. Deliberately pending-only —
    // delivered ones are visible in the OS notification center itself.
    var pendingMigrationNotifications: @Sendable () async -> [PendingMigrationNotification] = { [] }
}
