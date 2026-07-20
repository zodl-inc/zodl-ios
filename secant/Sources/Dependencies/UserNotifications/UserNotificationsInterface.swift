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
    // pending + delivered, "migration." prefix
    var cancelMigrationNotifications: @Sendable () async -> Void
    // delivered ONLY — pending (manual ready reminder) must survive
    var clearDeliveredMigrationNotifications: @Sendable () async -> Void
}
