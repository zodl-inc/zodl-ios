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
            let request = BGProcessingTaskRequest(identifier: MigrationBGTask.identifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInSeconds)
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false
            try? BGTaskScheduler.shared.submit(request)
        },
        cancel: {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: MigrationBGTask.identifier)
        }
    )

    static let noOp = MigrationBGScheduler(scheduleNextRun: { _ in }, cancel: { })
}
