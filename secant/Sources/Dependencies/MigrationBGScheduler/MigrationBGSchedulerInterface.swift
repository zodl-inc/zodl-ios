//
//  MigrationBGSchedulerInterface.swift
//  zodl
//
//  Wraps submitting/cancelling the migration BGProcessingTaskRequest, isolated so feature code can
//  schedule background sends without touching BGTaskScheduler directly.
//

import ComposableArchitecture
import Foundation

enum MigrationBGTask {
    /// Must match the entry in every target's `BGTaskSchedulerPermittedIdentifiers`.
    static let identifier = "co.electriccoin.ironwood_migration"
}

extension DependencyValues {
    var migrationBGScheduler: MigrationBGScheduler {
        get { self[MigrationBGScheduler.self] }
        set { self[MigrationBGScheduler.self] = newValue }
    }
}

@DependencyClient
struct MigrationBGScheduler: Sendable {
    /// Submit a request to run the migration background task no earlier than `earliestInSeconds`
    /// from now. Used by the worker's idle-gap deferral (retry just past `lastActivity + 1 h`).
    var scheduleNextRun: @Sendable (_ earliestInSeconds: TimeInterval) -> Void
    /// Submit the FIRST run after signing: eligible from the start of the night, or now if already
    /// inside the night (so a mid-night start uses the rest of tonight).
    var scheduleFirstRun: @Sendable () -> Void
    /// Submit a SUBSEQUENT run after a transfer: eligible from the next night's start (~one per night).
    var scheduleNightlyRun: @Sendable () -> Void
    /// Cancel any pending migration background task request.
    var cancel: @Sendable () -> Void
}

/// Computes the `BGProcessingTaskRequest.earliestBeginDate` floor for migration runs.
///
/// `earliestBeginDate` is only a floor — iOS picks the actual moment and there is no window-end API,
/// so eligibility is `[floor, ∞)`. To give iOS the whole night we anchor the floor to the start of the
/// night (9 PM) rather than a precise hour, and use `now` when already inside the night so a mid-night
/// start isn't pushed a full day out.
enum MigrationNightlyWindow {
    /// Start of the night window (local hour). Scheduled-run floors are anchored here.
    static let windowStartHour = 21
    /// End of the night window (local hour, exclusive). Used only to decide "are we inside the night".
    static let windowEndHour = 6

    /// True when `date`'s local hour is inside the night window: `hour >= 21 || hour < 6`.
    static func isWithinNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= windowStartHour || hour < windowEndHour
    }

    /// Floor for the FIRST run after signing: `now` if already inside the night, else today's 21:00.
    static func firstRunBegin(after now: Date, calendar: Calendar = .current) -> Date {
        if isWithinNight(now, calendar: calendar) {
            return now
        }
        return windowStart(onDayOf: now, calendar: calendar)
    }

    /// Floor for a SUBSEQUENT run: the start (21:00) of the next night — today 21:00 if `now` is
    /// before 21:00 (including early-morning runs), else tomorrow 21:00.
    static func nextNightBegin(after now: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.component(.hour, from: now)
        let tonight = windowStart(onDayOf: now, calendar: calendar)
        if hour < windowStartHour {
            return tonight
        }
        return calendar.date(byAdding: .day, value: 1, to: tonight) ?? tonight
    }

    /// 21:00 on the same calendar day as `date`.
    private static func windowStart(onDayOf date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .hour, value: windowStartHour, to: startOfDay) ?? date
    }
}
