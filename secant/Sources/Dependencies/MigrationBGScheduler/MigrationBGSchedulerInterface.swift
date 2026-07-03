//
//  MigrationBGSchedulerInterface.swift
//  Zashi
//
//  Background-refresh status check + scheduling seam for the Orchard -> Ironwood migration's
//  background execution (MOB-1467): the `co.electriccoin.migration_transfer` `BGProcessingTask`
//  cadence (§8.3) in scheduled mode, or a pre-scheduled "ready to send" local notification in
//  manual mode — see `MigrationBGSchedulerLiveKey`'s `WakeupAction` decision function.
//

import UIKit
import ComposableArchitecture

extension DependencyValues {
    var migrationBGScheduler: MigrationBGSchedulerClient {
        get { self[MigrationBGSchedulerClient.self] }
        set { self[MigrationBGSchedulerClient.self] = newValue }
    }
}

@DependencyClient
struct MigrationBGSchedulerClient: Sendable {
    var backgroundRefreshStatus: @Sendable () async -> UIBackgroundRefreshStatus = { .available }
    // Arms the next wakeup (+30 min rule): BG task request in scheduled mode, pre-scheduled
    // "ready to send" notification in manual mode. First-check: no-ops (cancels) if migration is
    // already `.complete`.
    var scheduleFirstWindow: @Sendable () async -> Void
    // Arms the next wakeup (+6.5 h rule), same branching as scheduleFirstWindow. Also the reset
    // point after a manual/immediate foreground send.
    var scheduleNextWindow: @Sendable () async -> Void
    // Cancels the pending BG task request and every migration-prefixed notification (pending +
    // delivered).
    var cancelAll: @Sendable () async -> Void
}

/// Background-task identifier for the migration transfer wakeup (AppDelegate registers with it;
/// prototype precedent).
enum MigrationBGTask {
    static let identifier = "co.electriccoin.migration_transfer"
}
