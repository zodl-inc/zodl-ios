//
//  AppDelegateAction.swift
//  Zashi
//
//  Created by Lukáš Korba on 27.03.2022.
//

import Foundation
import BackgroundTasks

enum AppDelegateAction: Equatable {
    case didFinishLaunching
    case didEnterBackground
    case willEnterForeground
    case backgroundTask(BGProcessingTask)
    case migrationBackgroundTask(BGProcessingTask)
    case migrationBackgroundTaskExpired
    /// R8-T5 (S4): the tapped notification's account, hex-encoded (`Data.hexEncodedString()`,
    /// matching every compose site's own encoding) — `nil` for a legacy/no-account payload. Read
    /// off `UNNotificationResponse.notification.request.content.userInfo` by
    /// `MigrationNotificationCenterDelegate` in `AppDelegate.swift`.
    /// MOB-1511 (W3): `isTorFailure` marks the dedicated Tor-failure notification — its tap routes
    /// to the Tor-failure sheet over Home instead of opening the migration flow.
    case migrationNotificationTapped(accountUUID: String?, isTorFailure: Bool)
}
