//
//  MigrationBGSchedulerInterface.swift
//  Zashi
//
//  Background-refresh status check + scheduling seams for the Orchard -> Ironwood migration's
//  background execution (MOB-1467). Only `backgroundRefreshStatus` is live in this ticket
//  (MOB-1466); the scheduling members are inert stubs the coordinator calls at the right cadence
//  points so MOB-1467 only has to fill the `LiveKey`, never touch call sites.
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
    // +30 min rule — no-op until MOB-1467
    var scheduleFirstWindow: @Sendable () -> Void
    // +6.5 h rule — no-op until MOB-1467
    var scheduleNextWindow: @Sendable () -> Void
    // no-op until MOB-1467
    var cancelAll: @Sendable () -> Void
}
