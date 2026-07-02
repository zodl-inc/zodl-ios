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
    /// Submit the FIRST run: eligible ~1 hour after the transfer schedule is created. Every schedule
    /// (re)creation — plan confirmation, recreating an invalid/expired transfer, rescheduling a
    /// stalled one — calls this to reset the cadence.
    var scheduleFirstRun: @Sendable () -> Void
    /// Submit the next run in the cadence: eligible ~6.5 hours from now (safely past the 288-block
    /// ≈ 6-hour send-window offset). Chained at the end of each background run while transfers remain.
    var scheduleSubsequentRun: @Sendable () -> Void
    /// Cancel any pending migration background task request.
    var cancel: @Sendable () -> Void
}

/// Floors for the migration background cadence. `earliestBeginDate` is only a floor — iOS picks the
/// actual execution moment — but this is the schedule we request: first run one hour after the
/// transfer schedule is (re)created, then one run every ~6.5 hours until the migration completes.
enum MigrationBGRunPolicy {
    /// Floor for the FIRST run after the transfer schedule is created or re-created.
    static let firstRunDelay: TimeInterval = 60 * 60
    /// Floor between consecutive background runs while transfers remain — deliberately past the
    /// 6-hour transfer cadence so each run finds its next transfer's window already open.
    static let subsequentRunDelay: TimeInterval = 6.5 * 60 * 60
}
