//
//  MigrationNotificationTests.swift
//  zodlTests
//
//  Covers `MigrationNotification` (Dependencies/UserNotifications/MigrationNotification.swift)
//  for MOB-1467: the stable "migration."-prefixed `identifier` per case, the localized `title`/
//  `body` (§4.4 matrix copy verbatim), and format-arg rendering (transfer numbers, hour counts,
//  the `Zatoshi.decimalString()` remaining-amount rendering). Pure enum, no shared state ->
//  no `.serialized`.
//

import Testing
import Foundation
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationNotificationTests {
    // MARK: - identifier

    @Test func identifierTable() {
        struct Row {
            let name: String
            let notification: MigrationNotification
            let expected: String
        }

        let rows: [Row] = [
            Row(
                name: "transferComplete",
                notification: MigrationNotification.transferComplete(number: 1, total: 5, nextInHours: 6, remaining: Zatoshi(100)),
                expected: "migration.transferComplete"
            ),
            Row(
                name: "transferWaiting",
                notification: MigrationNotification.transferWaiting(number: 2),
                expected: "migration.transferWaiting"
            ),
            Row(
                name: "planNeedsUpdate",
                notification: MigrationNotification.planNeedsUpdate,
                expected: "migration.planNeedsUpdate"
            ),
            Row(
                name: "manualTransferReady",
                notification: MigrationNotification.manualTransferReady(number: 3),
                expected: "migration.manualTransferReady"
            ),
            Row(
                name: "migrationComplete",
                notification: MigrationNotification.migrationComplete,
                expected: "migration.complete"
            )
        ]

        for row in rows {
            #expect(row.notification.identifier == row.expected, "Row \(row.name)")
            #expect(row.notification.identifier.hasPrefix(MigrationNotification.identifierPrefix), "Row \(row.name) prefix")
        }
    }

    @Test func identifiersAreAllUnique() {
        let notifications: [MigrationNotification] = [
            MigrationNotification.transferComplete(number: 1, total: 1, nextInHours: 1, remaining: Zatoshi.zero),
            MigrationNotification.transferWaiting(number: 1),
            MigrationNotification.planNeedsUpdate,
            MigrationNotification.manualTransferReady(number: 1),
            MigrationNotification.migrationComplete
        ]

        let identifiers = Set(notifications.map { $0.identifier })
        #expect(identifiers.count == notifications.count)
    }

    // MARK: - title

    @Test func titleTable() {
        struct Row {
            let name: String
            let notification: MigrationNotification
            let expected: String
        }

        let rows: [Row] = [
            Row(
                name: "transferComplete",
                notification: MigrationNotification.transferComplete(number: 1, total: 5, nextInHours: 6, remaining: Zatoshi(100)),
                expected: "Migration update"
            ),
            Row(
                name: "transferWaiting",
                notification: MigrationNotification.transferWaiting(number: 2),
                expected: "Action needed"
            ),
            Row(
                name: "planNeedsUpdate",
                notification: MigrationNotification.planNeedsUpdate,
                expected: "Action needed"
            ),
            Row(
                name: "manualTransferReady",
                notification: MigrationNotification.manualTransferReady(number: 3),
                expected: "Action needed"
            ),
            Row(
                name: "migrationComplete",
                notification: MigrationNotification.migrationComplete,
                expected: "Migration complete"
            )
        ]

        for row in rows {
            #expect(row.notification.title == row.expected, "Row \(row.name)")
        }
    }

    // MARK: - body — §4.4 matrix copy verbatim, incl. format-arg rendering

    @Test func transferCompleteBodyRendersAllFourArgs() {
        let notification = MigrationNotification.transferComplete(
            number: 2,
            total: 5,
            nextInHours: 6,
            remaining: Zatoshi(123_456_789)
        )

        let expected = "Transfer 2 of 5 complete — next send in ~6 hours. "
            + "\(Zatoshi(123_456_789).decimalString()) ZEC remaining in Orchard."
        #expect(notification.body == expected)
    }

    @Test func transferCompleteBodyRendersZeroRemaining() {
        let notification = MigrationNotification.transferComplete(
            number: 5,
            total: 5,
            nextInHours: 0,
            remaining: Zatoshi.zero
        )

        let expected = "Transfer 5 of 5 complete — next send in ~0 hours. "
            + "\(Zatoshi.zero.decimalString()) ZEC remaining in Orchard."
        #expect(notification.body == expected)
    }

    @Test func transferWaitingBodyRendersNumber() {
        let notification = MigrationNotification.transferWaiting(number: 3)

        #expect(notification.body == "Transfer 3 waiting. Open ZODL to send or re-schedule.")
    }

    @Test func planNeedsUpdateBodyIsFixedCopy() {
        let notification = MigrationNotification.planNeedsUpdate

        #expect(notification.body == "Migration plan needs update. Open ZODL to review the details.")
    }

    @Test func manualTransferReadyBodyRendersNumber() {
        let notification = MigrationNotification.manualTransferReady(number: 4)

        #expect(notification.body == "Transfer 4 — ready to send. Open ZODL to review the details.")
    }

    @Test func migrationCompleteBodyIsFixedCopy() {
        let notification = MigrationNotification.migrationComplete

        #expect(notification.body == "Migration complete. Open ZODL to review the details.")
    }

    // MARK: - Equatable

    @Test func transferCompleteIsEquatableByAllPayloadFields() {
        let a = MigrationNotification.transferComplete(number: 1, total: 5, nextInHours: 6, remaining: Zatoshi(100))
        let b = MigrationNotification.transferComplete(number: 1, total: 5, nextInHours: 6, remaining: Zatoshi(100))
        let c = MigrationNotification.transferComplete(number: 2, total: 5, nextInHours: 6, remaining: Zatoshi(100))

        #expect(a == b)
        #expect(a != c)
    }
}
