//
//  MigrationBackgroundTimingTests.swift
//  zodlTests
//
//  Nightly-window scheduling math (`MigrationNightlyWindow`) and the background worker's 1-hour
//  idle guard (`MigrationBackgroundWorker`).
//

import Testing
import Foundation
import os
import ComposableArchitecture
@testable import zodl_internal
@preconcurrency import ZcashLightClientKit

@Suite
struct MigrationNightlyWindowTests {
    /// Fixed UTC calendar so the hour math is deterministic regardless of the machine's timezone.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }

    /// A date on 2026-06-15 at the given local (UTC) time.
    private func at(hour: Int, minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 6
        comps.day = 15
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps) ?? Date(timeIntervalSince1970: 0)
    }

    @Test func isWithinNightTrueInsideWindow() {
        #expect(MigrationNightlyWindow.isWithinNight(at(hour: 21), calendar: calendar))
        #expect(MigrationNightlyWindow.isWithinNight(at(hour: 23, minute: 30), calendar: calendar))
        #expect(MigrationNightlyWindow.isWithinNight(at(hour: 3, minute: 30), calendar: calendar))
        #expect(MigrationNightlyWindow.isWithinNight(at(hour: 5, minute: 59), calendar: calendar))
    }

    @Test func isWithinNightFalseOutsideWindow() {
        #expect(!MigrationNightlyWindow.isWithinNight(at(hour: 6), calendar: calendar))
        #expect(!MigrationNightlyWindow.isWithinNight(at(hour: 12), calendar: calendar))
        #expect(!MigrationNightlyWindow.isWithinNight(at(hour: 20, minute: 59), calendar: calendar))
    }

    @Test func firstRunBeginUsesNowWhenInsideNight() {
        let earlyMorning = at(hour: 3, minute: 30)
        #expect(MigrationNightlyWindow.firstRunBegin(after: earlyMorning, calendar: calendar) == earlyMorning)
        let lateEvening = at(hour: 23)
        #expect(MigrationNightlyWindow.firstRunBegin(after: lateEvening, calendar: calendar) == lateEvening)
    }

    @Test func firstRunBeginUsesTonightNinePMWhenDaytime() {
        #expect(MigrationNightlyWindow.firstRunBegin(after: at(hour: 14), calendar: calendar) == at(hour: 21))
        // 7 AM is just past the night window — wait for tonight's 9 PM.
        #expect(MigrationNightlyWindow.firstRunBegin(after: at(hour: 7), calendar: calendar) == at(hour: 21))
    }

    @Test func nextNightBeginIsTonightNinePMBeforeNinePM() {
        // An early-morning run's next night is tonight 9 PM.
        #expect(MigrationNightlyWindow.nextNightBegin(after: at(hour: 3), calendar: calendar) == at(hour: 21))
        #expect(MigrationNightlyWindow.nextNightBegin(after: at(hour: 14), calendar: calendar) == at(hour: 21))
    }

    @Test func nextNightBeginIsTomorrowNinePMAtOrAfterNinePM() {
        let tomorrowNinePM = calendar.date(byAdding: .day, value: 1, to: at(hour: 21)) ?? Date(timeIntervalSince1970: 0)
        #expect(MigrationNightlyWindow.nextNightBegin(after: at(hour: 23), calendar: calendar) == tomorrowNinePM)
        #expect(MigrationNightlyWindow.nextNightBegin(after: at(hour: 21), calendar: calendar) == tomorrowNinePM)
    }
}

@Suite
struct MigrationBackgroundWorkerIdleGuardTests {
    private static let inProgress = MigrationState.inProgress(
        MigrationProgress(completedTransfers: 0, totalTransfers: 3, remainingOrchard: Zatoshi(0), nextTransferReadyAtHeight: nil)
    )

    @Test func scheduledRunSkipsWhenWithinOneHourOfActivity() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let executeCalls = OSAllocatedUnfairLock(initialState: 0)
        let nightlyCalls = OSAllocatedUnfairLock(initialState: 0)
        let scheduledSeconds = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)
        let recordedOutcome = OSAllocatedUnfairLock<MigrationBackgroundRun.Outcome?>(initialState: nil)

        let outcome = await withDependencies {
            $0.date.now = { now }
            $0.migrationActivity.lastActivity = { now.addingTimeInterval(-30 * 60) }
            $0.migrationSDK.isSyncRequiredBeforeNextTransfer = { false }
            $0.migrationSDK.executeNextPendingTransfer = { _ in
                executeCalls.withLock { $0 += 1 }
                return TransferResult.success(txId: "tx-should-not-send")
            }
            $0.migrationSDK.getMigrationState = { Self.inProgress }
            $0.migrationSDK.getMigrationProgress = { nil }
            $0.migrationSDK.recordBackgroundRun = { outcomeArg in
                recordedOutcome.withLock { $0 = outcomeArg }
            }
            $0.migrationBGScheduler.scheduleNextRun = { seconds in
                scheduledSeconds.withLock { $0 = seconds }
            }
            $0.migrationBGScheduler.scheduleNightlyRun = { nightlyCalls.withLock { $0 += 1 } }
            $0.localNotification.post = { _, _, _ in }
        } operation: {
            let worker = MigrationBackgroundWorker()
            return await worker.runMigrationStep(trigger: .scheduledTask)
        }

        #expect(outcome == .tooSoonAfterActivity)
        #expect(executeCalls.withLock { $0 } == 0)
        #expect(nightlyCalls.withLock { $0 } == 0)
        #expect(recordedOutcome.withLock { $0 } == .skippedTooSoon)
        // Rescheduled to lastActivity + 1h → 30 minutes from `now`.
        let seconds = scheduledSeconds.withLock { $0 }
        #expect(seconds != nil)
        if let seconds {
            #expect(abs(seconds - 30 * 60) < 0.001)
        }
    }

    @Test func scheduledRunSendsWhenGapSatisfied() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let executeCalls = OSAllocatedUnfairLock(initialState: 0)

        let outcome = await withDependencies {
            $0.date.now = { now }
            $0.migrationActivity.lastActivity = { now.addingTimeInterval(-2 * 60 * 60) }
            $0.migrationSDK.isSyncRequiredBeforeNextTransfer = { false }
            $0.migrationSDK.executeNextPendingTransfer = { _ in
                executeCalls.withLock { $0 += 1 }
                return TransferResult.success(txId: "tx-1")
            }
            $0.migrationSDK.getMigrationState = { Self.inProgress }
            $0.migrationSDK.getMigrationProgress = { nil }
            $0.migrationSDK.recordBackgroundRun = { _ in }
            $0.migrationBGScheduler.scheduleNextRun = { _ in }
            $0.migrationBGScheduler.scheduleNightlyRun = { }
            $0.localNotification.post = { _, _, _ in }
        } operation: {
            let worker = MigrationBackgroundWorker()
            return await worker.runMigrationStep(trigger: .scheduledTask)
        }

        #expect(executeCalls.withLock { $0 } == 1)
        #expect(outcome == .result(.success(txId: "tx-1")))
    }

    @Test func scheduledRunSendsWhenNoActivityRecorded() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let executeCalls = OSAllocatedUnfairLock(initialState: 0)

        await withDependencies {
            $0.date.now = { now }
            $0.migrationActivity.lastActivity = { nil }
            $0.migrationSDK.isSyncRequiredBeforeNextTransfer = { false }
            $0.migrationSDK.executeNextPendingTransfer = { _ in
                executeCalls.withLock { $0 += 1 }
                return TransferResult.success(txId: "tx-2")
            }
            $0.migrationSDK.getMigrationState = { Self.inProgress }
            $0.migrationSDK.getMigrationProgress = { nil }
            $0.migrationSDK.recordBackgroundRun = { _ in }
            $0.migrationBGScheduler.scheduleNightlyRun = { }
            $0.localNotification.post = { _, _, _ in }
        } operation: {
            let worker = MigrationBackgroundWorker()
            _ = await worker.runMigrationStep(trigger: .scheduledTask)
        }

        #expect(executeCalls.withLock { $0 } == 1)
    }

    @Test func manualRunBypassesGuardAndSends() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let executeCalls = OSAllocatedUnfairLock(initialState: 0)

        await withDependencies {
            $0.date.now = { now }
            // Active one minute ago — a scheduled run would skip, but a manual run must still send.
            $0.migrationActivity.lastActivity = { now.addingTimeInterval(-60) }
            $0.migrationSDK.isSyncRequiredBeforeNextTransfer = { false }
            $0.migrationSDK.executeNextPendingTransfer = { _ in
                executeCalls.withLock { $0 += 1 }
                return TransferResult.success(txId: "tx-3")
            }
            $0.migrationSDK.getMigrationState = { Self.inProgress }
            $0.migrationSDK.getMigrationProgress = { nil }
            $0.migrationSDK.recordBackgroundRun = { _ in }
            $0.migrationBGScheduler.scheduleNightlyRun = { }
            $0.localNotification.post = { _, _, _ in }
        } operation: {
            let worker = MigrationBackgroundWorker()
            _ = await worker.runMigrationStep(trigger: .manual)
        }

        #expect(executeCalls.withLock { $0 } == 1)
    }
}
