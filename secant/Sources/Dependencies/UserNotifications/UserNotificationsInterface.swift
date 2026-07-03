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
    // nil date = deliver now
    var scheduleMigrationNotification: @Sendable (MigrationNotification, Date?) async -> Void
    // pending + delivered, "migration." prefix
    var cancelMigrationNotifications: @Sendable () async -> Void
    // delivered ONLY — pending (manual ready reminder) must survive
    var clearDeliveredMigrationNotifications: @Sendable () async -> Void
}
