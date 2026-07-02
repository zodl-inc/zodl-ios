//
//  MigrationBackgroundWorker.swift
//  zodl
//
//  Runs a single migration step. This is the production code path executed by the BGTaskScheduler
//  handler in AppDelegate, and also by the DEBUG "Run background task now" control — so the whole
//  chain (background execution → broadcast → notification → reschedule) is testable on demand.
//
//  A real scheduled run (`trigger == .scheduledTask`) refuses to broadcast within one hour of the
//  user's last app activity and reschedules itself past that gap; the debug "Run now" button
//  (`trigger == .manual`) bypasses the gap and sends immediately.
//
//  Per the proposal, sync is NEVER triggered here — broadcast and sync are decoupled in time.
//

import ComposableArchitecture
import Foundation

/// What triggered a background migration step. A real scheduled task enforces the 1-hour idle gap;
/// the debug "Run now" button bypasses it and sends immediately.
enum MigrationRunTrigger: Sendable {
    case scheduledTask
    case manual
}

/// What a single background migration step did — surfaced to the DEBUG panel so an armed result
/// (especially a silent network-error retry) is observable. The production caller ignores it.
enum MigrationStepOutcome: Equatable, Sendable {
    /// `isSyncRequiredBeforeNextTransfer` was true — the step bailed without broadcasting.
    case syncRequired
    /// No pending transfer — migration is finished or not started.
    case nothingPending
    /// A scheduled run woke within an hour of the user's last app activity — it skipped without
    /// broadcasting and rescheduled itself past the gap.
    case tooSoonAfterActivity
    /// A transfer was attempted; carries the broadcast result.
    case result(TransferResult)
}

struct MigrationBackgroundWorker: Sendable {
    @Dependency(\.migrationSDK) var migrationSDK
    @Dependency(\.localNotification) var localNotification
    @Dependency(\.migrationBGScheduler) var migrationBGScheduler
    @Dependency(\.migrationActivity) var migrationActivity
    @Dependency(\.date) var date

    /// Minimum time since the user's last app activity before a scheduled run may broadcast.
    private let minActivityGap: TimeInterval = 60 * 60

    @discardableResult
    func runMigrationStep(trigger: MigrationRunTrigger) async -> MigrationStepOutcome {
        let outcome = await performStep(trigger: trigger)
        // PROTOTYPE: record every run (real BGTask or the debug "Run now") so the debug panel can show
        // when background tasks actually fired and what the transfer send returned.
        migrationSDK.recordBackgroundRun(Self.runLogOutcome(for: outcome))
        return outcome
    }

    private func performStep(trigger: MigrationRunTrigger) async -> MigrationStepOutcome {
        // A scheduled run must not broadcast within an hour of the user last using the app. If it woke
        // too soon, skip without sending and reschedule just past the gap. The debug "Run now" button
        // (.manual) bypasses this and sends immediately.
        if trigger == .scheduledTask, let lastActivity = migrationActivity.lastActivity() {
            let elapsed = date.now().timeIntervalSince(lastActivity)
            if elapsed < minActivityGap {
                migrationBGScheduler.scheduleNextRun(minActivityGap - elapsed)
                return .tooSoonAfterActivity
            }
        }

        // Sync must not run inside the background task. If the next transfer needs a sync first, bail
        // out and let the foreground app handle the sync, decoupled in time from the broadcast.
        guard !migrationSDK.isSyncRequiredBeforeNextTransfer() else { return .syncRequired }

        let options = NetworkPrivacyOptions(useTor: false)
        guard let result = await migrationSDK.executeNextPendingTransfer(options) else {
            // Nothing pending — migration is finished or not started.
            return .nothingPending
        }

        switch result {
        case let .success(txId):
            await postSuccessNotification(txId: txId)
            // Chain the next run (~6.5 h) while transfers remain.
            if migrationSDK.getMigrationState() != .complete {
                migrationBGScheduler.scheduleSubsequentRun()
            }
        case .networkError, .invalidNote, .expired:
            // Simplified error reporting (per product guidance): one generic notification, no per-cause UI.
            await localNotification.post(
                "ZODL",
                "There was a problem with a migration transfer. Open ZODL to continue.",
                "ironwood-migration-error"
            )
            // Keep the cadence alive — a failed run must not end background delivery. The next run
            // retries (network errors) or finds the recreated schedule (the app resets the cadence
            // via scheduleFirstRun when the user recovers in-app first).
            migrationBGScheduler.scheduleSubsequentRun()
        }
        return .result(result)
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

    private static func runLogOutcome(for outcome: MigrationStepOutcome) -> MigrationBackgroundRun.Outcome {
        switch outcome {
        case .syncRequired:
            return .syncRequired
        case .nothingPending:
            return .nothingPending
        case .tooSoonAfterActivity:
            return .skippedTooSoon
        case let .result(result):
            switch result {
            case let .success(txId):
                return .sent(txId: txId)
            case .networkError:
                return .networkError
            case .invalidNote:
                return .invalidNote
            case .expired:
                return .expired
            }
        }
    }
}
