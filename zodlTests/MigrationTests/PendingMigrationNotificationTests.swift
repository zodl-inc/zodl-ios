//
//  PendingMigrationNotificationTests.swift
//  zodlTests
//
//  Table tests for the What's New debug screen's `print_notifs` report formatter.
//

import Foundation
import Testing
import UserNotifications
@testable import zodl_internal

@Suite struct PendingMigrationNotificationTests {
    static let now = Date(timeIntervalSince1970: 0)
    static let utc = TimeZone.gmt

    static func notification(
        identifier: String = "migration.stepReady_aabbcc",
        title: String = "Step ready",
        body: String = "Open Zodl.",
        fireDate: Date? = nil,
        accountUUID: String? = nil
    ) -> PendingMigrationNotification {
        PendingMigrationNotification(
            identifier: identifier,
            title: title,
            body: body,
            fireDate: fireDate,
            accountUUID: accountUUID
        )
    }

    @Test func emptyListReportsAuthorizationAndNoPending() {
        let report = PendingMigrationNotification.debugReport(
            [],
            authorization: .authorized,
            now: Self.now,
            timeZone: Self.utc
        )
        #expect(report == """
        Notification authorization: authorized

        No pending migration notifications.
        """)
    }

    @Test func singleNotificationRendersAllFields() {
        let report = PendingMigrationNotification.debugReport(
            [
                Self.notification(
                    fireDate: Date(timeIntervalSince1970: 59_100),
                    accountUUID: "aabbcc"
                )
            ],
            authorization: .authorized,
            now: Self.now,
            timeZone: Self.utc
        )
        #expect(report == """
        Notification authorization: authorized

        1 pending migration notification(s):

        #1 migration.stepReady_aabbcc
           fires: 1970-01-01 16:25:00 (in 16h 25m)
           account: aabbcc
           title: Step ready
           body: Open Zodl.
        """)
    }

    @Test func nilFireDateAndNilAccountRenderPlaceholders() {
        let report = PendingMigrationNotification.debugReport(
            [Self.notification(identifier: "migration.timeToSync")],
            authorization: .authorized,
            now: Self.now,
            timeZone: Self.utc
        )
        #expect(report == """
        Notification authorization: authorized

        1 pending migration notification(s):

        #1 migration.timeToSync
           fires: unknown
           account: — (legacy payload)
           title: Step ready
           body: Open Zodl.
        """)
    }

    @Test func sortsByFireDateThenIdentifierWithNilDatesLast() {
        let report = PendingMigrationNotification.debugReport(
            [
                Self.notification(identifier: "migration.d"),
                Self.notification(identifier: "migration.c", fireDate: Date(timeIntervalSince1970: 59_100)),
                Self.notification(identifier: "migration.b", fireDate: Date(timeIntervalSince1970: 300)),
                Self.notification(identifier: "migration.a", fireDate: Date(timeIntervalSince1970: 59_100))
            ],
            authorization: .authorized,
            now: Self.now,
            timeZone: Self.utc
        )
        let order = report
            .split(separator: "\n")
            .filter { $0.hasPrefix("#") }
            .map { String($0) }
        #expect(order == [
            "#1 migration.b",
            "#2 migration.a",
            "#3 migration.c",
            "#4 migration.d"
        ])
    }

    @Test(arguments: [
        (TimeInterval(-60), "1969-12-31 23:59:00 (overdue)"),
        (TimeInterval(59), "1970-01-01 00:00:59 (in <1m)"),
        (TimeInterval(300), "1970-01-01 00:05:00 (in 5m)"),
        (TimeInterval(59_100), "1970-01-01 16:25:00 (in 16h 25m)"),
        (TimeInterval(183_600), "1970-01-03 03:00:00 (in 2d 3h)")
    ])
    func fireTimeRendering(offset: TimeInterval, expected: String) {
        let report = PendingMigrationNotification.debugReport(
            [Self.notification(fireDate: Date(timeIntervalSince1970: offset))],
            authorization: .authorized,
            now: Self.now,
            timeZone: Self.utc
        )
        #expect(report.contains("   fires: \(expected)"))
    }

    @Test func deniedAuthorizationRendersWarning() {
        let report = PendingMigrationNotification.debugReport(
            [],
            authorization: .denied,
            now: Self.now,
            timeZone: Self.utc
        )
        #expect(report.hasPrefix("Notification authorization: denied — nothing will be delivered"))
    }

    @Test func notDeterminedAuthorizationRendersHint() {
        let report = PendingMigrationNotification.debugReport(
            [],
            authorization: .notDetermined,
            now: Self.now,
            timeZone: Self.utc
        )
        #expect(report.hasPrefix("Notification authorization: notDetermined — never requested"))
    }
}
