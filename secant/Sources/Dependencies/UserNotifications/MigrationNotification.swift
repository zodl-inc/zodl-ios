//
//  MigrationNotification.swift
//  Zashi
//
//  Pure mapping from a migration background event onto the local notification's identifier/
//  title/body (MOB-1467, feature spec §4.4). `MigrationBannerVariant`-style: no SDK dependency,
//  no I/O — `MigrationBGSchedulerLiveKey` and `RootInitialization`'s BG session decision tree
//  construct a case and hand it to `userNotifications.scheduleMigrationNotification(_:at:accountUUID:)`.
//  Table-tested directly (see MigrationNotificationTests).
//
//  Copy follows the lock-screen mocks' consistent split (MOB-1478 W9): `title` carries the
//  specific fact (incl. any transfer number), `body` is a short generic call-to-action — except
//  `transferComplete`, whose §4.4 matrix copy is unchanged and stays fully in `body`.
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
    /// MOB-1496: fired instead of `.migrationComplete` when the stored run's `.complete` (per-run
    /// now, not "nothing left to migrate" — the final engine caps how much a single run covers)
    /// turned out to still have a non-empty fresh plan behind it (see
    /// `MigrationManagerImpl.evaluateMigrationRemainder`'s doc). No payload: unlike
    /// `.transferComplete`, nothing about the NEXT run's shape is known yet at notification time.
    case migrationBatchComplete
    /// MOB-1511 (W3, Figma 4207:8768): a background migration broadcast failed on a Tor-class
    /// route (the same event that arms `isPendingBackgroundTorPrompt`) — generic copy per design;
    /// the specifics live in the Tor-failure sheet its tap routes to.
    case migrationTorFailure

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
        case .migrationBatchComplete:
            return "\(Self.identifierPrefix)batchComplete"
        case .migrationTorFailure:
            return "\(Self.identifierPrefix)torFailure"
        }
    }

    var title: String {
        switch self {
        case .transferComplete:
            return String(localizable: .migrationNotificationTransferCompleteTitle)
        case let .transferWaiting(number):
            return String(localizable: .migrationNotificationTransferWaitingTitle(number))
        case .planNeedsUpdate:
            return String(localizable: .migrationNotificationPlanNeedsUpdateTitle)
        case let .manualTransferReady(number):
            return String(localizable: .migrationNotificationManualTransferReadyTitle(number))
        case .migrationComplete:
            return String(localizable: .migrationNotificationMigrationCompleteTitle)
        case .migrationBatchComplete:
            return String(localizable: .migrationNotificationBatchCompleteTitle)
        case .migrationTorFailure:
            return String(localizable: .migrationNotificationTorFailureTitle)
        }
    }

    /// §4.4 matrix copy verbatim for `transferComplete`, whose body carries the full fact-plus-
    /// CTA sentence. Every other case follows the lock-screen split: `title` now carries the
    /// specific fact (incl. any transfer number), so `body` here is just the short generic
    /// call-to-action. `remaining` renders via `Zatoshi.decimalString()`; `nextInHours` is the
    /// armed-window interval rounded to hours (caller-computed).
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
        case .transferWaiting:
            return String(localizable: .migrationNotificationTransferWaitingBody)
        case .planNeedsUpdate:
            return String(localizable: .migrationNotificationPlanNeedsUpdateBody)
        case .manualTransferReady:
            return String(localizable: .migrationNotificationManualTransferReadyBody)
        case .migrationComplete:
            return String(localizable: .migrationNotificationMigrationCompleteBody)
        case .migrationBatchComplete:
            return String(localizable: .migrationNotificationBatchCompleteBody)
        case .migrationTorFailure:
            // Deliberately the same generic "open ZODL" line the complete notification uses —
            // per design, the notification names only the fact; the sheet carries the details.
            return String(localizable: .migrationNotificationMigrationCompleteBody)
        }
    }
}
