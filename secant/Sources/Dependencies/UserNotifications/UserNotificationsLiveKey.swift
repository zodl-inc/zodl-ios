//
//  UserNotificationsLiveKey.swift
//  Zashi
//

import UserNotifications
import ComposableArchitecture

extension UserNotificationsClient: DependencyKey {
    static let liveValue: UserNotificationsClient = Self.live()

    static func live() -> Self {
        UserNotificationsClient(
            authorizationStatus: {
                await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            },
            requestAuthorization: {
                do {
                    return try await UNUserNotificationCenter.current().requestAuthorization(
                        options: [.alert, .sound, .badge]
                    )
                } catch {
                    return false
                }
            }
        )
    }
}
