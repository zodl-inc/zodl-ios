//
//  AppDelegateAction.swift
//  Zashi
//
//  Created by Lukáš Korba on 27.03.2022.
//

import Foundation

enum AppDelegateAction: Equatable {
    case didFinishLaunching
    case didEnterBackground
    case willEnterForeground
    case backgroundTask(PlatformBackgroundTask)
    /// PHASE 4: a migration notification was tapped. `accountUUID` is the hex-encoded account the
    /// notification was COMPOSED for, so a tap opens that account's run rather than whichever one
    /// happens to be selected now; `nil` falls back to the selected account. `isTorFailure` routes
    /// to the failure sheet instead of the flow (its own surface arrives with Phase 5).
    case migrationNotificationTapped(accountUUID: String?, isTorFailure: Bool)
    /// F-C9-4 companion (2026-08-05): a migration poke DELIVERED while the app was foregrounded.
    /// D9 still presents nothing (the SmartBanner is the story) — but the delivery instant IS the
    /// window signal our own arming lane computed, and foregrounded there is no banner to tap, so
    /// the landing itself drives the tick belt once. `accountUUID` as above.
    case migrationPokeLandedInForeground(accountUUID: String?)
}
