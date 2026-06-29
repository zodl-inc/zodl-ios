//
//  MigrationBGSchedulerLiveKey.swift
//  zodl
//

import BackgroundTasks
import ComposableArchitecture
import Foundation

extension MigrationBGScheduler: DependencyKey {
    static let liveValue = MigrationBGScheduler(
        scheduleNextRun: { earliestInSeconds in
            submit(earliestBeginDate: Date(timeIntervalSinceNow: earliestInSeconds))
        },
        scheduleFirstRun: {
            submit(earliestBeginDate: MigrationNightlyWindow.firstRunBegin(after: Date()))
        },
        scheduleNightlyRun: {
            submit(earliestBeginDate: MigrationNightlyWindow.nextNightBegin(after: Date()))
        },
        cancel: {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: MigrationBGTask.identifier)
        }
    )

    static let noOp = MigrationBGScheduler(
        scheduleNextRun: { _ in },
        scheduleFirstRun: { },
        scheduleNightlyRun: { },
        cancel: { }
    )

    /// Submit the migration `BGProcessingTaskRequest` with the given floor. `earliestBeginDate` is only
    /// a floor; iOS runs the task at an opportune moment after it (network required, charging not).
    private static func submit(earliestBeginDate: Date) {
        let request = BGProcessingTaskRequest(identifier: MigrationBGTask.identifier)
        request.earliestBeginDate = earliestBeginDate
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}
