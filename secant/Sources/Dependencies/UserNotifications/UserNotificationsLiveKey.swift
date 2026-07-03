//
//  UserNotificationsLiveKey.swift
//  Zashi
//
//  LiveKey itself is untested (system framework) — everything decision-shaped (which
//  `MigrationNotification` case, which date) lives in the pure layer / reducer that calls these
//  members, per MOB-1467.
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
            },
            scheduleMigrationNotification: { notification, date in
                let content = UNMutableNotificationContent()
                content.title = notification.title
                content.body = notification.body
                content.sound = .default

                let trigger: UNTimeIntervalNotificationTrigger?
                if let date {
                    // Immediate delivery (nil date) needs no trigger; otherwise fire at the
                    // interval between now and the target date, floored at a hair above zero so
                    // a past/imminent date still delivers rather than being rejected.
                    let interval = max(date.timeIntervalSinceNow, 0.1)
                    trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                } else {
                    trigger = nil
                }

                let request = UNNotificationRequest(
                    identifier: notification.identifier,
                    content: content,
                    trigger: trigger
                )

                try? await UNUserNotificationCenter.current().add(request)
            },
            cancelMigrationNotifications: {
                let center = UNUserNotificationCenter.current()
                let pendingIds = await center.pendingNotificationRequests()
                    .map { $0.identifier }
                    .filter { $0.hasPrefix(MigrationNotification.identifierPrefix) }
                center.removePendingNotificationRequests(withIdentifiers: pendingIds)

                let deliveredIds = await center.deliveredNotifications()
                    .map { $0.request.identifier }
                    .filter { $0.hasPrefix(MigrationNotification.identifierPrefix) }
                center.removeDeliveredNotifications(withIdentifiers: deliveredIds)
            },
            clearDeliveredMigrationNotifications: {
                let center = UNUserNotificationCenter.current()
                let deliveredIds = await center.deliveredNotifications()
                    .map { $0.request.identifier }
                    .filter { $0.hasPrefix(MigrationNotification.identifierPrefix) }
                center.removeDeliveredNotifications(withIdentifiers: deliveredIds)
            }
        )
    }
}
