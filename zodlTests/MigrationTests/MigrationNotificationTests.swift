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
            ),
            Row(
                name: "migrationBatchComplete",
                notification: MigrationNotification.migrationBatchComplete,
                expected: "migration.batchComplete"
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
            MigrationNotification.migrationComplete,
            MigrationNotification.migrationBatchComplete
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
                expected: "Transfer 2 waiting"
            ),
            Row(
                name: "planNeedsUpdate",
                notification: MigrationNotification.planNeedsUpdate,
                expected: "Migration plan needs update"
            ),
            Row(
                name: "manualTransferReady",
                notification: MigrationNotification.manualTransferReady(number: 3),
                expected: "Transfer 3 — ready to send"
            ),
            Row(
                name: "migrationComplete",
                notification: MigrationNotification.migrationComplete,
                expected: "Migration complete"
            ),
            Row(
                name: "migrationBatchComplete",
                notification: MigrationNotification.migrationBatchComplete,
                expected: "Migration batch finished"
            )
        ]

        for row in rows {
            #expect(row.notification.title == row.expected, "Row \(row.name)")
        }
    }

    @Test func transferWaitingTitleRendersNumber() {
        let notification = MigrationNotification.transferWaiting(number: 7)

        #expect(notification.title == "Transfer 7 waiting")
    }

    @Test func manualTransferReadyTitleRendersNumber() {
        let notification = MigrationNotification.manualTransferReady(number: 9)

        #expect(notification.title == "Transfer 9 — ready to send")
    }

    // MARK: - body — §4.4 matrix copy verbatim for `transferComplete`; every other case is now a
    // short generic CTA (MOB-1478 W9), since the specific fact (incl. any transfer number) moved
    // to `title`.

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

    @Test func transferWaitingBodyIsFixedCopy() {
        let notification = MigrationNotification.transferWaiting(number: 3)

        #expect(notification.body == "Open ZODL to send or re-schedule.")
    }

    @Test func planNeedsUpdateBodyIsFixedCopy() {
        let notification = MigrationNotification.planNeedsUpdate

        #expect(notification.body == "Open ZODL to review the details.")
    }

    @Test func manualTransferReadyBodyIsFixedCopy() {
        let notification = MigrationNotification.manualTransferReady(number: 4)

        #expect(notification.body == "Open ZODL to review the details.")
    }

    @Test func migrationCompleteBodyIsFixedCopy() {
        let notification = MigrationNotification.migrationComplete

        #expect(notification.body == "Open ZODL to review the details.")
    }

    /// MOB-1496: unlike every other case above, this one's body is NOT the generic
    /// "Open ZODL to review the details." CTA — it explicitly says more remains, since that's the
    /// whole reason this case exists instead of `.migrationComplete`.
    @Test func migrationBatchCompleteBodyIsFixedCopy() {
        let notification = MigrationNotification.migrationBatchComplete

        #expect(notification.body == "More funds to migrate. Open ZODL to continue.")
    }

    /// MOB-1511 (W3, Figma 4207:8768): the Tor-failure notification — generic copy per design (the
    /// sheet its tap routes to carries the specifics), body shared with the complete notification.
    @Test func torFailureIdentifierTitleAndBody() {
        let notification = MigrationNotification.migrationTorFailure

        #expect(notification.identifier == "migration.torFailure")
        #expect(notification.title == "Migration Failure")
        #expect(notification.body == "Open ZODL to review the details.")
    }

    // MARK: - Equatable

    @Test func transferCompleteIsEquatableByAllPayloadFields() {
        let a = MigrationNotification.transferComplete(number: 1, total: 5, nextInHours: 6, remaining: Zatoshi(100))
        let b = MigrationNotification.transferComplete(number: 1, total: 5, nextInHours: 6, remaining: Zatoshi(100))
        let c = MigrationNotification.transferComplete(number: 2, total: 5, nextInHours: 6, remaining: Zatoshi(100))

        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - requestIdentifier(accountUUID:) (MOB-1513, gap 1)
    //
    // iOS's `UNNotificationRequest` replaces any pending/delivered request sharing its identifier —
    // the bare, case-only `identifier` above let account B's pending request silently replace
    // account A's for the same kind. `requestIdentifier(accountUUID:)` is the per-account form
    // every actual schedule/removal site must use instead: the SAME hex-encoded account suffix
    // `PerAccountCodableStorage.key(for:)` uses, so two accounts' notifications of the same kind
    // coexist while a same-account re-schedule of the same kind still replaces (deterministic
    // derivation from (case, account) alone).

    @Test func requestIdentifierWithNilAccountUUIDFallsBackToBareIdentifier() {
        let notification = MigrationNotification.manualTransferReady(number: 1)

        #expect(notification.requestIdentifier(accountUUID: nil) == notification.identifier)
    }

    @Test func requestIdentifierAppendsAccountUUIDSuffix() {
        let notification = MigrationNotification.transferWaiting(number: 2)

        #expect(notification.requestIdentifier(accountUUID: "aabbcc") == "migration.transferWaiting_aabbcc")
    }

    /// Same-account replacement semantics: the SAME (case, account) pair always derives the SAME
    /// identifier, so re-scheduling the same kind for the same account still replaces (no drift
    /// from any hidden mutable state).
    @Test func requestIdentifierIsDeterministicForTheSameCaseAndAccount() {
        let first = MigrationNotification.planNeedsUpdate.requestIdentifier(accountUUID: "acct-a")
        let second = MigrationNotification.planNeedsUpdate.requestIdentifier(accountUUID: "acct-a")

        #expect(first == second)
    }

    /// The core gap-1 fix: two DIFFERENT accounts scheduling the SAME kind must derive DIFFERENT
    /// identifiers, so neither silently replaces the other's pending/delivered request.
    @Test func requestIdentifierDiffersAcrossAccountsForTheSameCase() {
        let notification = MigrationNotification.manualTransferReady(number: 3)

        let accountA = notification.requestIdentifier(accountUUID: "acct-a")
        let accountB = notification.requestIdentifier(accountUUID: "acct-b")

        #expect(accountA != accountB)
    }

    /// `cancelMigrationNotifications`/`clearDeliveredMigrationNotifications` filter by
    /// `hasPrefix(identifierPrefix)` — the per-account form must still match so that bulk (all-
    /// accounts) removal keeps working unchanged.
    @Test func requestIdentifierStillHasTheStablePrefix() {
        let notification = MigrationNotification.migrationComplete

        #expect(notification.requestIdentifier(accountUUID: "acct-a").hasPrefix(MigrationNotification.identifierPrefix))
    }

    /// Comprehensive collision check: every one of the seven real cases, across two accounts, must
    /// produce fourteen pairwise-distinct identifiers — proves the fix closes gap 1 for every kind,
    /// not just the two (`manualTransferReady`/`transferWaiting`) called out by name in the audit.
    @Test func twoAccountsAcrossEveryKindProduceAllDistinctIdentifiers() {
        let notifications: [MigrationNotification] = [
            MigrationNotification.transferComplete(number: 1, total: 1, nextInHours: 1, remaining: Zatoshi.zero),
            MigrationNotification.transferWaiting(number: 1),
            MigrationNotification.planNeedsUpdate,
            MigrationNotification.manualTransferReady(number: 1),
            MigrationNotification.migrationComplete,
            MigrationNotification.migrationBatchComplete,
            MigrationNotification.migrationTorFailure
        ]

        var identifiers: [String] = []
        for notification in notifications {
            identifiers.append(notification.requestIdentifier(accountUUID: "acct-a"))
            identifiers.append(notification.requestIdentifier(accountUUID: "acct-b"))
        }

        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers.count == 14)
    }
}
