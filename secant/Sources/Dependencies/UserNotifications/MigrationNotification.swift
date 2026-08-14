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
    /// route — generic copy per design. (The T5 prompt latch this once referenced was deleted,
    /// audit 2026-08-03 #16; the tor-hold indicator carries the surviving surface.)
    case migrationTorFailure
    /// PHASE 4 (D9) proposed a two-poke cadence: this fired at `window - lead` asking for a sync,
    /// `manualTransferReady` fired AT the window asking for a send. RETIRED — nothing schedules it
    /// any more. See `stepReady` below for what replaced the pair and why.
    ///
    /// Kept as a case (rather than deleted) only so `cancelMigrationNotifications` still recognises
    /// and clears one left pending by an older build. It is dead on every fresh install.
    case timeToSync(number: Int)
    /// THE notification. Exactly one is ever scheduled, wallet-wide.
    ///
    /// The migration has no background lane: nothing happens unless the user opens Zodl. Each open
    /// is one opportunity to evaluate state and take ONE step — sync, or send, or split, or
    /// re-plan. Which one it is depends on state at open time, so this poke deliberately promises
    /// none of them; it just says the migration can move.
    ///
    /// One step per open is not a simplification, it is the privacy property: a sync and a send
    /// should not be adjacent enough to be linked by an observer. That holds however long the user
    /// was away — waking up nine hours late does not earn the right to batch two actions.
    /// 2026-08-07: this used to name a ~600 s post-sync buffer as the mechanism; that buffer is
    /// deleted (a fixed delay is itself the pattern an observer keys on), so the one-step-per-open
    /// shape carries the property on its own.
    ///
    /// So there is exactly one moment worth poking about: when the NEXT step becomes due.
    /// No number, no account: by the time the user opens, state may have moved, and naming a
    /// transfer or an account in the poke would be a promise the app might not keep.
    case stepReady

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
        case .timeToSync:
            return "\(Self.identifierPrefix)timeToSync"

        case .stepReady:
            return "\(Self.identifierPrefix)stepReady"
        }
    }

    /// MOB-1513 (gap 1): the actual `UNNotificationRequest` identifier every schedule/removal site
    /// must use — `identifier` above suffixed with the SAME hex encoding
    /// `PerAccountCodableStorage.key(for:)` uses (`Data(accountUUID.id).hexEncodedString()`), via
    /// the already hex-encoded string every schedule site threads through as `accountUUID`. The
    /// bare `identifier` let iOS's replace-by-identifier semantics collapse two accounts' pending
    /// notifications of the same kind into one; the SAME (case, account) pair always derives the
    /// SAME string here, so a same-account re-schedule of the same kind still replaces its own
    /// prior pending/delivered request. `nil` (legacy/no-account payload) falls back to the bare
    /// `identifier` unchanged.
    func requestIdentifier(accountUUID: String?) -> String {
        guard let accountUUID else { return identifier }
        return "\(identifier)_\(accountUUID)"
    }

    var title: String {
        switch self {
        case .stepReady:
            return String(localizable: .migrationNotificationStepReadyTitle)
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
        case let .timeToSync(number):
            return String(localizable: .migrationNotificationTimeToSyncTitle(number))
        }
    }

    /// §4.4 matrix copy verbatim for `transferComplete`, whose body carries the full fact-plus-
    /// CTA sentence. Every other case follows the lock-screen split: `title` now carries the
    /// specific fact (incl. any transfer number), so `body` here is just the short generic
    /// call-to-action. `remaining` renders via `Zatoshi.decimalString()`; `nextInHours` is the
    /// armed-window interval rounded to hours (caller-computed).
    var body: String {
        switch self {
        case .stepReady:
            return String(localizable: .migrationNotificationStepReadyBody)
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
            // Deliberately the same generic "open Zodl" line the complete notification uses —
            // per design, the notification names only the fact; the sheet carries the details.
            return String(localizable: .migrationNotificationMigrationCompleteBody)
        case .timeToSync:
            return String(localizable: .migrationNotificationTimeToSyncBody)
        }
    }
}
