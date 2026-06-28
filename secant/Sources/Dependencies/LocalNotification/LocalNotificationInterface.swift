//
//  LocalNotificationInterface.swift
//  zodl
//
//  Thin wrapper over UNUserNotificationCenter for migration status notifications. The app had no
//  local-notification infrastructure before this feature.
//

import ComposableArchitecture
import UserNotifications

extension DependencyValues {
    var localNotification: LocalNotificationClient {
        get { self[LocalNotificationClient.self] }
        set { self[LocalNotificationClient.self] = newValue }
    }
}

@DependencyClient
struct LocalNotificationClient: Sendable {
    /// Requests alert/sound authorization. Returns whether it was granted.
    var requestAuthorization: @Sendable () async -> Bool = { false }
    /// Posts an immediate local notification.
    var post: @Sendable (_ title: String, _ body: String, _ identifier: String) async -> Void
    /// Clears pending + delivered notifications.
    var removeAll: @Sendable () async -> Void
}
