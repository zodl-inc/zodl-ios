//
//  MigrationBGSchedulerLiveKey.swift
//  Zashi
//

import UIKit
import ComposableArchitecture

extension MigrationBGSchedulerClient: DependencyKey {
    static let liveValue: MigrationBGSchedulerClient = Self.live()

    static func live() -> Self {
        MigrationBGSchedulerClient(
            backgroundRefreshStatus: {
                await MainActor.run {
                    UIApplication.shared.backgroundRefreshStatus
                }
            },
            // TODO: [MOB-1467] Schedule the first background-refresh window ~30 minutes after a
            // migration plan is committed (or re-committed via reschedule/recreate). Call sites in
            // MOB-1466 already invoke this at every cadence-reset point (plan committed; reschedule
            // confirmed; recovery recreate confirmed) — this only has to start honoring it.
            scheduleFirstWindow: { },
            // TODO: [MOB-1467] Schedule the next background-refresh window ~6.5 hours after the
            // previous one fired (§8.3 cadence), or after a manual/immediate foreground send
            // resets the cadence per the coordinator's call sites.
            scheduleNextWindow: { },
            // TODO: [MOB-1467] Cancel every pending background-refresh window (migration complete,
            // user backed out, etc).
            cancelAll: { }
        )
    }
}
