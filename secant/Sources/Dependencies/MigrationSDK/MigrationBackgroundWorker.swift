//
//  MigrationBackgroundWorker.swift
//  zodl
//
//  Runs a single migration step. This is the production code path executed by the BGTaskScheduler
//  handler in AppDelegate, and also by the DEBUG "Run background task now" control — so the whole
//  chain (background execution → broadcast → notification → reschedule) is testable on demand.
//
//  Per the proposal, sync is NEVER triggered here — broadcast and sync are decoupled in time.
//

import ComposableArchitecture
import Foundation

struct MigrationBackgroundWorker: Sendable {
    @Dependency(\.migrationSDK) var migrationSDK
    @Dependency(\.localNotification) var localNotification
    @Dependency(\.migrationBGScheduler) var migrationBGScheduler

    /// Reschedule delay for the next pending transfer (seconds). Short for the prototype.
    private let rescheduleDelay: TimeInterval = 60

    func runMigrationStep() async {
        // Sync must not run inside the background task. If the next transfer needs a sync first, bail
        // out and let the foreground app handle the sync, decoupled in time from the broadcast.
        guard !migrationSDK.isSyncRequiredBeforeNextTransfer() else { return }

        let options = NetworkPrivacyOptions(useTor: false)
        guard let result = await migrationSDK.executeNextPendingTransfer(options) else {
            // Nothing pending — migration is finished or not started.
            return
        }

        switch result {
        case let .success(txId):
            await postSuccessNotification(txId: txId)
            // Schedule the next window while transfers remain.
            if migrationSDK.getMigrationState() != .complete {
                migrationBGScheduler.scheduleNextRun(rescheduleDelay)
            }
        case .networkError, .invalidNote, .expired:
            // Simplified error reporting (per product guidance): one generic notification, no per-cause UI.
            await localNotification.post(
                "ZODL",
                "There was a problem with a migration transfer. Open ZODL to continue.",
                "ironwood-migration-error"
            )
        }
    }

    private func postSuccessNotification(txId: String) async {
        let body: String
        if migrationSDK.getMigrationState() == .complete {
            body = "Migration complete. Your ZEC has moved to Ironwood."
        } else if let progress = migrationSDK.getMigrationProgress() {
            body = "Transfer \(progress.completedTransfers) of \(progress.totalTransfers) complete."
        } else {
            body = "Migration transfer complete."
        }
        await localNotification.post("ZODL", body, "ironwood-migration-\(txId)")
    }
}
