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
    /// Submit a request to run the migration background task no earlier than `earliestInSeconds`.
    var scheduleNextRun: @Sendable (_ earliestInSeconds: TimeInterval) -> Void
    /// Cancel any pending migration background task request.
    var cancel: @Sendable () -> Void
}
