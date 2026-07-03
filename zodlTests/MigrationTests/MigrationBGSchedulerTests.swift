//
//  MigrationBGSchedulerTests.swift
//  zodlTests
//
//  Covers the pure `WakeupAction.decide` decision function
//  (Dependencies/MigrationBGScheduler/MigrationBGSchedulerLiveKey.swift) for MOB-1467: the
//  (state, isManualDelivery, window, nextTransferNumber) table — scheduled mode submits a BG
//  task, manual mode schedules the "ready" notification, and `.complete` always wins with
//  `.cancelAll` regardless of delivery mode. Pure enum/function, no SDK or framework touched
//  (never `BGTaskScheduler`/`UNUserNotificationCenter` in this file) -> no shared state ->
//  no `.serialized`.
//

import Testing
import Foundation
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationBGSchedulerTests {
    private static let window = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Non-complete states x scheduled/manual

    @Test func scheduledModeSubmitsTaskWithTheGivenWindow() {
        let action = WakeupAction.decide(
            state: MigrationState.notStarted,
            isManualDelivery: false,
            window: Self.window,
            nextTransferNumber: 1
        )

        #expect(action == WakeupAction.submitTask(earliestBeginDate: Self.window))
    }

    @Test func manualModeSchedulesReadyNotificationWithGivenWindowAndNumber() {
        let action = WakeupAction.decide(
            state: MigrationState.notStarted,
            isManualDelivery: true,
            window: Self.window,
            nextTransferNumber: 3
        )

        #expect(action == WakeupAction.scheduleReadyNotification(number: 3, at: Self.window))
    }

    @Test func inProgressScheduledModeSubmitsTask() {
        let progress = MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 5,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: 100
        )

        let action = WakeupAction.decide(
            state: MigrationState.inProgress(progress),
            isManualDelivery: false,
            window: Self.window,
            nextTransferNumber: 3
        )

        #expect(action == WakeupAction.submitTask(earliestBeginDate: Self.window))
    }

    @Test func inProgressManualModeSchedulesReadyNotification() {
        let progress = MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 5,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: 100
        )

        let action = WakeupAction.decide(
            state: MigrationState.inProgress(progress),
            isManualDelivery: true,
            window: Self.window,
            nextTransferNumber: 3
        )

        #expect(action == WakeupAction.scheduleReadyNotification(number: 3, at: Self.window))
    }

    @Test func requiresAttentionScheduledModeSubmitsTask() {
        let action = WakeupAction.decide(
            state: MigrationState.requiresAttention(AttentionReason.transferStalled(transferNumber: 2)),
            isManualDelivery: false,
            window: Self.window,
            nextTransferNumber: 2
        )

        #expect(action == WakeupAction.submitTask(earliestBeginDate: Self.window))
    }

    @Test func requiresAttentionManualModeSchedulesReadyNotification() {
        let action = WakeupAction.decide(
            state: MigrationState.requiresAttention(AttentionReason.invalidTransfer(transferId: "t1")),
            isManualDelivery: true,
            window: Self.window,
            nextTransferNumber: 1
        )

        #expect(action == WakeupAction.scheduleReadyNotification(number: 1, at: Self.window))
    }

    // MARK: - .complete always wins, regardless of mode

    @Test func completeStateCancelsAllInScheduledMode() {
        let action = WakeupAction.decide(
            state: MigrationState.complete,
            isManualDelivery: false,
            window: Self.window,
            nextTransferNumber: 1
        )

        #expect(action == WakeupAction.cancelAll)
    }

    @Test func completeStateCancelsAllInManualMode() {
        let action = WakeupAction.decide(
            state: MigrationState.complete,
            isManualDelivery: true,
            window: Self.window,
            nextTransferNumber: 1
        )

        #expect(action == WakeupAction.cancelAll)
    }

    // MARK: - Full table

    @Test func decisionTable() {
        struct Row {
            let name: String
            let state: MigrationState
            let isManualDelivery: Bool
            let nextTransferNumber: Int
            let expected: WakeupAction
        }

        let progress = MigrationProgress(
            completedTransfers: 1,
            totalTransfers: 4,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: 50
        )

        let rows: [Row] = [
            Row(
                name: "notStarted/scheduled",
                state: MigrationState.notStarted,
                isManualDelivery: false,
                nextTransferNumber: 1,
                expected: WakeupAction.submitTask(earliestBeginDate: Self.window)
            ),
            Row(
                name: "notStarted/manual",
                state: MigrationState.notStarted,
                isManualDelivery: true,
                nextTransferNumber: 1,
                expected: WakeupAction.scheduleReadyNotification(number: 1, at: Self.window)
            ),
            Row(
                name: "inProgress/scheduled",
                state: MigrationState.inProgress(progress),
                isManualDelivery: false,
                nextTransferNumber: 2,
                expected: WakeupAction.submitTask(earliestBeginDate: Self.window)
            ),
            Row(
                name: "inProgress/manual",
                state: MigrationState.inProgress(progress),
                isManualDelivery: true,
                nextTransferNumber: 2,
                expected: WakeupAction.scheduleReadyNotification(number: 2, at: Self.window)
            ),
            Row(
                name: "complete/scheduled",
                state: MigrationState.complete,
                isManualDelivery: false,
                nextTransferNumber: 5,
                expected: WakeupAction.cancelAll
            ),
            Row(
                name: "complete/manual",
                state: MigrationState.complete,
                isManualDelivery: true,
                nextTransferNumber: 5,
                expected: WakeupAction.cancelAll
            )
        ]

        for row in rows {
            let action = WakeupAction.decide(
                state: row.state,
                isManualDelivery: row.isManualDelivery,
                window: Self.window,
                nextTransferNumber: row.nextTransferNumber
            )

            #expect(action == row.expected, "Row \(row.name) expected \(row.expected) but got \(action)")
        }
    }
}
