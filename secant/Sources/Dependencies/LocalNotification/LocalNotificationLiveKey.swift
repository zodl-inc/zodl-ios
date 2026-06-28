//
//  LocalNotificationLiveKey.swift
//  zodl
//

import ComposableArchitecture
import UserNotifications

extension LocalNotificationClient: DependencyKey {
    static let liveValue = LocalNotificationClient(
        requestAuthorization: {
            let center = UNUserNotificationCenter.current()
            let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted ?? false
        },
        post: { title, body, identifier in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = UNNotificationSound.default
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        },
        removeAll: {
            let center = UNUserNotificationCenter.current()
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
        }
    )
}
