//
//  UserNotificationsInterface.swift
//  Zashi
//
//  Authorization-only seam over `UNUserNotificationCenter` for the Orchard -> Ironwood
//  migration's Notifications permission screen (MOB-1466). MOB-1467 extends this client with
//  local-notification scheduling (§4.4 matrix) — do not add those members here yet.
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
}
