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
            scheduleMigrationNotification: { notification, date, accountUUID in
                let content = UNMutableNotificationContent()
                content.title = notification.title
                content.body = notification.body
                content.sound = .default
                // R8-T5 (S4): carries the account this notification was composed for, so the tap
                // handler (`MigrationNotificationCenterDelegate` in `AppDelegate.swift`) can read it
                // back off `response.notification.request.content.userInfo` and route/switch to the
                // right account instead of always resolving `selectedWalletAccount`.
                if let accountUUID {
                    content.userInfo = ["accountUUID": accountUUID]
                }

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

                // MOB-1513 (gap 1): the per-account identifier — see `MigrationNotification
                // .requestIdentifier(accountUUID:)`'s doc for why the bare `identifier` alone
                // let two accounts' pending requests of the same kind silently replace each other.
                let request = UNNotificationRequest(
                    identifier: notification.requestIdentifier(accountUUID: accountUUID),
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
