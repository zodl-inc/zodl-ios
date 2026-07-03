//
//  MigrationCadence.swift
//  Zashi
//
//  Pure background-wakeup timing math for the Orchard -> Ironwood migration (MOB-1467, §8.3).
//  `window(margin:preferredExecutableAt:now:)` is the single formula both `scheduleFirstWindow`
//  and `scheduleNextWindow` use in the `MigrationBGSchedulerClient` LiveKey — only the margin
//  constant differs between them. Table-tested directly, no SDK dependency (see
//  MigrationCadenceTests).
//

import Foundation

enum MigrationCadence {
    static let firstWindowMargin: TimeInterval = 30 * 60          // §8.3
    static let nextWindowMargin: TimeInterval = 6.5 * 60 * 60     // §8.3

    /// earliestBeginDate for the next wakeup. The SDK's per-transfer executable time is
    /// authoritative when known; the app margin is both the fallback (stubs return nil) and a
    /// floor (never wake before the margin — §8.3's 30 min/6.5 h cushions over the SDK's
    /// ~10 min/~6 h expectations).
    static func window(margin: TimeInterval, preferredExecutableAt: Date?, now: Date) -> Date {
        max(preferredExecutableAt ?? Date.distantPast, now.addingTimeInterval(margin))
    }
}
