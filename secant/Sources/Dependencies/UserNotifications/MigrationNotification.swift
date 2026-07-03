//
//  MigrationNotification.swift
//  Zashi
//
//  Pure mapping from a migration background event onto the local notification's identifier/
//  title/body (MOB-1467, feature spec §4.4). `MigrationBannerVariant`-style: no SDK dependency,
//  no I/O — `MigrationBGSchedulerLiveKey` and `RootInitialization`'s BG session decision tree
//  construct a case and hand it to `userNotifications.scheduleMigrationNotification(_:at:)`.
//  Table-tested directly (see MigrationNotificationTests).
//
//  Titles are short new copy ("Migration update" / "Action needed" / "Migration complete") —
//  §4.4 only pins the bodies verbatim; PR flags these for design confirmation against the Figma
//  lock-screen mocks.
//

@preconcurrency import ZcashLightClientKit

enum MigrationNotification: Equatable, Sendable {
    /// Stable prefix shared by every identifier below — phase 2's tap-routing (matching a
    /// delivered notification's identifier) and `cancelMigrationNotifications`/
    /// `clearDeliveredMigrationNotifications` (filtering pending/delivered requests) both key off
    /// this constant rather than restating the literal.
    static let identifierPrefix = "migration."

    case transferComplete(number: Int, total: Int, nextInHours: Int, remaining: Zatoshi)
    case transferWaiting(number: Int)
    case planNeedsUpdate                 // covers BOTH matrix rows 3+4 (identical copy)
    case manualTransferReady(number: Int)
    case migrationComplete

    /// Stable, "migration."-prefixed — re-posting the same case replaces the previous pending/
    /// delivered notification (no dedup marker needed elsewhere).
    var identifier: String {
        switch self {
        case .transferComplete:
            return "\(Self.identifierPrefix)transferComplete"
        case .transferWaiting:
            return "\(Self.identifierPrefix)transferWaiting"
        case .planNeedsUpdate:
            return "\(Self.identifierPrefix)planNeedsUpdate"
        case .manualTransferReady:
            return "\(Self.identifierPrefix)manualTransferReady"
        case .migrationComplete:
            return "\(Self.identifierPrefix)complete"
        }
    }

    var title: String {
        switch self {
        case .transferComplete:
            return String(localizable: .migrationNotificationTransferCompleteTitle)
        case .transferWaiting, .planNeedsUpdate, .manualTransferReady:
            return String(localizable: .migrationNotificationActionNeededTitle)
        case .migrationComplete:
            return String(localizable: .migrationNotificationMigrationCompleteTitle)
        }
    }

    /// §4.4 matrix copy verbatim. `remaining` renders via `Zatoshi.decimalString()`;
    /// `nextInHours` is the armed-window interval rounded to hours (caller-computed).
    var body: String {
        switch self {
        case let .transferComplete(number, total, nextInHours, remaining):
            return String(
                localizable: .migrationNotificationTransferCompleteBody(
                    number,
                    total,
                    nextInHours,
                    remaining.decimalString()
                )
            )
        case let .transferWaiting(number):
            return String(localizable: .migrationNotificationTransferWaitingBody(number))
        case .planNeedsUpdate:
            return String(localizable: .migrationNotificationPlanNeedsUpdateBody)
        case let .manualTransferReady(number):
            return String(localizable: .migrationNotificationManualTransferReadyBody(number))
        case .migrationComplete:
            return String(localizable: .migrationNotificationMigrationCompleteBody)
        }
    }
}
