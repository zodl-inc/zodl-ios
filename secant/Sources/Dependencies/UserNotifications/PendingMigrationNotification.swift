//
//  PendingMigrationNotification.swift
//  Zashi
//
//  Read-back value for the What's New debug screen's `print_notifs` command: one pending
//  "migration." local-notification request, plus the pure report formatter. The LiveKey maps
//  `UNNotificationRequest`s into this; formatting stays here so it is table-testable — same
//  pure-layer split as `MigrationNotification`.
//

import Foundation
import UserNotifications

struct PendingMigrationNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let fireDate: Date?
    let accountUUID: String?
}

extension PendingMigrationNotification {
    /// The `print_notifs` output: authorization header first — a denied/undetermined status makes
    /// every arm a silent no-op, which is the first thing to rule out when a poke never arrives —
    /// then one block per pending request, soonest first. Nothing is truncated: the identifier's
    /// account suffix is often the very detail under investigation, and the `account:` line is
    /// printed separately so a divergence between the two shows up as itself a bug.
    static func debugReport(
        _ notifications: [PendingMigrationNotification],
        authorization: UNAuthorizationStatus,
        now: Date,
        timeZone: TimeZone = .current
    ) -> String {
        var lines: [String] = ["Notification authorization: \(describe(authorization))", ""]

        guard !notifications.isEmpty else {
            lines.append("No pending migration notifications.")
            return lines.joined(separator: "\n")
        }

        lines.append("\(notifications.count) pending migration notification(s):")

        let sorted = notifications.sorted { lhs, rhs in
            switch (lhs.fireDate, rhs.fireDate) {
            case let (.some(lhsDate), .some(rhsDate)):
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
                return lhs.identifier < rhs.identifier
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.identifier < rhs.identifier
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone

        for (index, notification) in sorted.enumerated() {
            lines.append("")
            lines.append("#\(index + 1) \(notification.identifier)")
            if let fireDate = notification.fireDate {
                let absolute = formatter.string(from: fireDate)
                let relative = relativeDescription(of: fireDate, since: now)
                lines.append("   fires: \(absolute) (\(relative))")
            } else {
                lines.append("   fires: unknown")
            }
            if let accountUUID = notification.accountUUID {
                lines.append("   account: \(accountUUID)")
            } else {
                lines.append("   account: — (legacy payload)")
            }
            lines.append("   title: \(notification.title)")
            lines.append("   body: \(notification.body)")
        }

        return lines.joined(separator: "\n")
    }

    private static func describe(_ authorization: UNAuthorizationStatus) -> String {
        switch authorization {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied — nothing will be delivered"
        case .notDetermined:
            return "notDetermined — never requested"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown"
        }
    }

    private static func relativeDescription(of fireDate: Date, since now: Date) -> String {
        let interval = fireDate.timeIntervalSince(now)
        if interval < 0 {
            return "overdue"
        }
        let totalMinutes = Int(interval) / 60
        if totalMinutes < 1 {
            return "in <1m"
        }
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return "in \(days)d \(hours)h"
        }
        if hours > 0 {
            return "in \(hours)h \(minutes)m"
        }
        return "in \(minutes)m"
    }
}
