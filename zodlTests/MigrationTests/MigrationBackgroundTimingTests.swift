//
//  MigrationBackgroundTimingTests.swift
//  zodlTests
//
//  Background-run cadence policy (`MigrationBGRunPolicy`) and the background worker's 1-hour
//  idle guard + run chaining (`MigrationBackgroundWorker`).
//

import Testing
import Foundation
import os
import ComposableArchitecture
@testable import zodl_internal
@preconcurrency import ZcashLightClientKit

@Suite
struct MigrationBGRunPolicyTests {
    // The requested cadence: first run ~1 h after the schedule is (re)created, then one run every
    // ~6.5 h — deliberately past the 288-block ≈ 6-hour transfer window offset.
    @Test func firstRunIsOneHourOut() {
        #expect(MigrationBGRunPolicy.firstRunDelay == 60 * 60)
    }

    @Test func subsequentRunsClearTheSixHourWindowOffset() {
        #expect(MigrationBGRunPolicy.subsequentRunDelay == 6.5 * 60 * 60)
        #expect(MigrationBGRunPolicy.subsequentRunDelay > 6 * 60 * 60)
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
        let subsequentCalls = OSAllocatedUnfairLock(initialState: 0)
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
            $0.migrationBGScheduler.scheduleSubsequentRun = { subsequentCalls.withLock { $0 += 1 } }
            $0.localNotification.post = { _, _, _ in }
        } operation: {
            let worker = MigrationBackgroundWorker()
            return await worker.runMigrationStep(trigger: .scheduledTask)
        }

        #expect(outcome == .tooSoonAfterActivity)
        #expect(executeCalls.withLock { $0 } == 0)
        #expect(subsequentCalls.withLock { $0 } == 0)
        #expect(recordedOutcome.withLock { $0 } == .skippedTooSoon)
        // Rescheduled to lastActivity + 1h → 30 minutes from `now`.
        let seconds = scheduledSeconds.withLock { $0 }
        #expect(seconds != nil)
        if let seconds {
            #expect(abs(seconds - 30 * 60) < 0.001)
        }
    }

    @Test func scheduledRunSendsAndChainsTheNextRun() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let executeCalls = OSAllocatedUnfairLock(initialState: 0)
        let subsequentCalls = OSAllocatedUnfairLock(initialState: 0)

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
            $0.migrationBGScheduler.scheduleSubsequentRun = { subsequentCalls.withLock { $0 += 1 } }
            $0.localNotification.post = { _, _, _ in }
        } operation: {
            let worker = MigrationBackgroundWorker()
            return await worker.runMigrationStep(trigger: .scheduledTask)
        }

        #expect(executeCalls.withLock { $0 } == 1)
        #expect(outcome == .result(.success(txId: "tx-1")))
        // While transfers remain, each run chains the next one (~6.5 h out).
        #expect(subsequentCalls.withLock { $0 } == 1)
    }

    @Test func failedRunStillChainsTheNextRun() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let subsequentCalls = OSAllocatedUnfairLock(initialState: 0)
        let notifications = OSAllocatedUnfairLock(initialState: 0)

        let outcome = await withDependencies {
            $0.date.now = { now }
            $0.migrationActivity.lastActivity = { nil }
            $0.migrationSDK.isSyncRequiredBeforeNextTransfer = { false }
            $0.migrationSDK.executeNextPendingTransfer = { _ in
                TransferResult.networkError(retryable: true)
            }
            $0.migrationSDK.getMigrationState = { Self.inProgress }
            $0.migrationSDK.getMigrationProgress = { nil }
            $0.migrationSDK.recordBackgroundRun = { _ in }
            $0.migrationBGScheduler.scheduleSubsequentRun = { subsequentCalls.withLock { $0 += 1 } }
            $0.localNotification.post = { _, _, _ in notifications.withLock { $0 += 1 } }
        } operation: {
            let worker = MigrationBackgroundWorker()
            return await worker.runMigrationStep(trigger: .scheduledTask)
        }

        #expect(outcome == .result(.networkError(retryable: true)))
        #expect(notifications.withLock { $0 } == 1)
        // A failed run must not end the background cadence — the next run retries or finds the
        // schedule the user recreated in-app.
        #expect(subsequentCalls.withLock { $0 } == 1)
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
            $0.migrationBGScheduler.scheduleSubsequentRun = { }
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
            $0.migrationBGScheduler.scheduleSubsequentRun = { }
            $0.localNotification.post = { _, _, _ in }
        } operation: {
            let worker = MigrationBackgroundWorker()
            _ = await worker.runMigrationStep(trigger: .manual)
        }

        #expect(executeCalls.withLock { $0 } == 1)
    }
}
