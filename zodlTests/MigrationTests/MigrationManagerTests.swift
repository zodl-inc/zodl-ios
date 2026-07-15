//
//  MigrationManagerTests.swift
//  zodlTests
//
//  Covers `MigrationManagerClient`'s pure derivations (Dependencies/MigrationManager/) for
//  MOB-1466: `MigrationDerivations.bannerVariant`/`reentryRoute` tables, the 10-minute
//  sync<->send gate math (`MigrationGateStorage`), and every UserDefaults-backed persistence
//  roundtrip. `.serialized` because every test shares the `UserDefaults` global.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized)
struct MigrationManagerTests {
    // MARK: - bannerVariant

    @Test func notStartedWithPositiveBalanceIsRequired() {
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.notStarted,
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi(1),
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.required)
    }

    @Test func notStartedWithZeroBalanceIsNil() {
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.notStarted,
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == nil)
    }

    @Test func readyToProposeWithPositiveBalanceIsRequired() {
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.readyToPropose,
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi(500),
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.required)
    }

    @Test func readyToProposeWithZeroBalanceIsNil() {
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.readyToPropose,
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == nil)
    }

    @Test func splitPendingConfirmationIsSplitting() {
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.splitPendingConfirmation,
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.splitting)
    }

    @Test func inProgressManualAndDueIsTransferReady() {
        let progress = MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 5,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: 100
        )

        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.inProgress(progress),
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: true,
            isNextTransferDue: true,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.transferReady(number: 3))
    }

    @Test func inProgressManualButNotDueIsPlainProgress() {
        let progress = MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 5,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: 100
        )

        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.inProgress(progress),
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: true,
            isNextTransferDue: false,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.inProgress(done: 2, total: 5))
    }

    @Test func inProgressNonManualIsPlainProgressEvenWhenDue() {
        let progress = MigrationProgress(
            completedTransfers: 1,
            totalTransfers: 4,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: 100
        )

        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.inProgress(progress),
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: true,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.inProgress(done: 1, total: 4))
    }

    @Test func requiresAttentionSyncRequiredBeforeNextRendersAsPlainProgress() {
        // The LiveKey normalizes `.requiresAttention(.syncRequiredBeforeNext)` into
        // `.inProgress(progress)` using its own `getMigrationProgress()` snapshot before calling
        // the pure function (`syncRequiredBeforeNext` itself carries no progress payload) — so at
        // this layer it is indistinguishable from a plain `.inProgress` state.
        let progress = MigrationProgress(
            completedTransfers: 3,
            totalTransfers: 6,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: 100
        )

        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.inProgress(progress),
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.inProgress(done: 3, total: 6))
    }

    @Test func requiresAttentionTransferStalledIsTransferWaiting() {
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.requiresAttention(AttentionReason.transferStalled(transferNumber: 3)),
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.transferWaiting(number: 3))
    }

    @Test func requiresAttentionInvalidTransferIsUpdatePlan() {
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.requiresAttention(AttentionReason.invalidTransfer(transferId: "t1")),
            hasInvalid: true,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.updatePlan)
    }

    @Test func requiresAttentionTransferExpiredUsesExpiredRowBounds() {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "r0", index: 0, amount: Zatoshi(100), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "r1", index: 1, amount: Zatoshi(100), status: .expired, hoursFromNow: 0),
            MigrationTransferRow(id: "r2", index: 2, amount: Zatoshi(100), status: .expired, hoursFromNow: 0),
            MigrationTransferRow(id: "r3", index: 3, amount: Zatoshi(100), status: .expired, hoursFromNow: 0),
            MigrationTransferRow(id: "r4", index: 4, amount: Zatoshi(100), status: .pending, hoursFromNow: 1)
        ]

        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.requiresAttention(AttentionReason.transferExpired),
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: rows
        )

        #expect(variant == MigrationBannerVariant.transfersExpired(first: 2, last: 4))
    }

    @Test func requiresAttentionTransferExpiredFallsBackToOneAndTotalWhenNoRowsAreExpired() {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "r0", index: 0, amount: Zatoshi(100), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "r1", index: 1, amount: Zatoshi(100), status: .pending, hoursFromNow: 1)
        ]

        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.requiresAttention(AttentionReason.transferExpired),
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: rows
        )

        #expect(variant == MigrationBannerVariant.transfersExpired(first: 1, last: 2))
    }

    @Test func requiresAttentionTransferExpiredFallsBackToOneAndZeroWithNoRowsAtAll() {
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.requiresAttention(AttentionReason.transferExpired),
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.transfersExpired(first: 1, last: 0))
    }

    @Test func completeUnacknowledgedIsComplete() {
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.complete,
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.complete)
    }

    @Test func completeAcknowledgedIsNil() {
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.complete,
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: true,
            transferRows: []
        )

        #expect(variant == nil)
    }

    @Test func acknowledgedFlagIsIgnoredOutsideCompleteState() {
        // The acknowledged flag is only consulted while state is `.complete` — a `notStarted`
        // state with a positive balance must still show `.required` even if `isCompleteAcknowledged`
        // is stale-true from a previous migration (that reset is `reconcile()`'s job, exercised by
        // `reconcileClearsAcknowledgedFlagWhenStateIsNotComplete` /
        // `reconcileKeepsAcknowledgedFlagWhenStateIsComplete` below, not this pure table).
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.notStarted,
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi(1),
            isCompleteAcknowledged: true,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.required)
    }

    @Test func gateClosedBeatsMaximallyOfferingBannerInput() {
        // MOB-1483: `isIronwoodActivated: false` must win over even the input that otherwise
        // produces the strongest banner (`notStarted` + a positive balance -> `.required`).
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: false,
            state: MigrationState.notStarted,
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi(1),
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == nil)
    }

    // MARK: - reentryRoute

    @Test func hasInvalidTransfersWinsOverEverythingElse() {
        let progress = MigrationProgress(
            completedTransfers: 1,
            totalTransfers: 2,
            remainingOrchard: Zatoshi.zero,
            nextTransferReadyAtHeight: nil
        )

        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: MigrationState.complete,
            hasInvalid: true,
            hasOverdue: true,
            isManualDelivery: true,
            isNextTransferDue: true,
            isCompleteAcknowledged: false,
            progress: progress
        )

        #expect(route == MigrationReentryRoute.recovery(isExpired: false))
    }

    @Test func gateClosedBeatsMaximallyOfferingReentryInput() {
        // MOB-1483: `isIronwoodActivated: false` must win over even the top of the priority
        // chain — this is the same maximally-offering input as
        // `hasInvalidTransfersWinsOverEverythingElse` (which would-be produce `.recovery`, and
        // with `hasInvalid` false would-be produce `.statusResume`), but with the gate closed it
        // must still be `.entry`.
        let progress = MigrationProgress(
            completedTransfers: 1,
            totalTransfers: 2,
            remainingOrchard: Zatoshi.zero,
            nextTransferReadyAtHeight: nil
        )

        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: false,
            state: MigrationState.complete,
            hasInvalid: true,
            hasOverdue: true,
            isManualDelivery: true,
            isNextTransferDue: true,
            isCompleteAcknowledged: false,
            progress: progress
        )

        #expect(route == MigrationReentryRoute.entry)
    }

    @Test func invalidTransferWithTransferExpiredAttentionReasonIsExpiredRecovery() {
        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: MigrationState.requiresAttention(AttentionReason.transferExpired),
            hasInvalid: true,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            isCompleteAcknowledged: false,
            progress: nil
        )

        #expect(route == MigrationReentryRoute.recovery(isExpired: true))
    }

    @Test func invalidTransferWithOtherAttentionReasonIsNonExpiredRecovery() {
        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: MigrationState.requiresAttention(AttentionReason.invalidTransfer(transferId: "t1")),
            hasInvalid: true,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            isCompleteAcknowledged: false,
            progress: nil
        )

        #expect(route == MigrationReentryRoute.recovery(isExpired: false))
    }

    @Test func hasOverdueWinsOverInProgressAndComplete() {
        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: MigrationState.complete,
            hasInvalid: false,
            hasOverdue: true,
            isManualDelivery: false,
            isNextTransferDue: false,
            isCompleteAcknowledged: false,
            progress: nil
        )

        #expect(route == MigrationReentryRoute.statusResume)
    }

    @Test func manualDueWinsOverPlainInProgress() {
        let progress = MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 5,
            remainingOrchard: Zatoshi.zero,
            nextTransferReadyAtHeight: 100
        )

        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: MigrationState.inProgress(progress),
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: true,
            isNextTransferDue: true,
            isCompleteAcknowledged: false,
            progress: progress
        )

        #expect(route == MigrationReentryRoute.reviewManual(step: 3, total: 5))
    }

    @Test func manualButNotDueFallsThroughToPlainInProgress() {
        let progress = MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 5,
            remainingOrchard: Zatoshi.zero,
            nextTransferReadyAtHeight: 100
        )

        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: MigrationState.inProgress(progress),
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: true,
            isNextTransferDue: false,
            isCompleteAcknowledged: false,
            progress: progress
        )

        #expect(route == MigrationReentryRoute.statusProgress)
    }

    @Test func dueButNotManualFallsThroughToPlainInProgress() {
        let progress = MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 5,
            remainingOrchard: Zatoshi.zero,
            nextTransferReadyAtHeight: 100
        )

        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: MigrationState.inProgress(progress),
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: true,
            isCompleteAcknowledged: false,
            progress: progress
        )

        #expect(route == MigrationReentryRoute.statusProgress)
    }

    @Test func plainInProgressIsStatusProgress() {
        let progress = MigrationProgress(
            completedTransfers: 0,
            totalTransfers: 3,
            remainingOrchard: Zatoshi.zero,
            nextTransferReadyAtHeight: nil
        )

        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: MigrationState.inProgress(progress),
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            isCompleteAcknowledged: false,
            progress: progress
        )

        #expect(route == MigrationReentryRoute.statusProgress)
    }

    @Test func completeUnacknowledgedIsCompleteRoute() {
        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: MigrationState.complete,
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            isCompleteAcknowledged: false,
            progress: nil
        )

        #expect(route == MigrationReentryRoute.complete)
    }

    @Test func completeAcknowledgedFallsThroughToEntry() {
        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: MigrationState.complete,
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            isCompleteAcknowledged: true,
            progress: nil
        )

        #expect(route == MigrationReentryRoute.entry)
    }

    @Test func splitPendingConfirmationIsNoteSplitProgress() {
        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: MigrationState.splitPendingConfirmation,
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            isCompleteAcknowledged: false,
            progress: nil
        )

        #expect(route == MigrationReentryRoute.noteSplitProgress)
    }

    @Test func notStartedIsEntry() {
        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: MigrationState.notStarted,
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            isCompleteAcknowledged: false,
            progress: nil
        )

        #expect(route == MigrationReentryRoute.entry)
    }

    @Test func readyToProposeIsEntry() {
        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: MigrationState.readyToPropose,
            hasInvalid: false,
            hasOverdue: false,
            isManualDelivery: false,
            isNextTransferDue: false,
            isCompleteAcknowledged: false,
            progress: nil
        )

        #expect(route == MigrationReentryRoute.entry)
    }

    @Test func allSevenRoutesInPriorityOrder() {
        // §4.3 priority order, verified as one table so a future reordering trips a single test.
        struct Row {
            let name: String
            let isIronwoodActivated: Bool
            let hasInvalid: Bool
            let hasOverdue: Bool
            let isManualDelivery: Bool
            let isNextTransferDue: Bool
            let isCompleteAcknowledged: Bool
            let state: MigrationState
            let expected: MigrationReentryRoute
        }

        let progress = MigrationProgress(
            completedTransfers: 1,
            totalTransfers: 4,
            remainingOrchard: Zatoshi.zero,
            nextTransferReadyAtHeight: 100
        )

        let rows: [Row] = [
            // MOB-1483: the activation gate outranks every other row — a closed gate beats even
            // the highest-priority pre-gate input (`hasInvalid`, which would otherwise win row 1).
            Row(
                name: "0: gate closed",
                isIronwoodActivated: false,
                hasInvalid: true,
                hasOverdue: false,
                isManualDelivery: false,
                isNextTransferDue: false,
                isCompleteAcknowledged: false,
                state: MigrationState.requiresAttention(AttentionReason.invalidTransfer(transferId: "t1")),
                expected: MigrationReentryRoute.entry
            ),
            Row(
                name: "1: recovery",
                isIronwoodActivated: true,
                hasInvalid: true,
                hasOverdue: false,
                isManualDelivery: false,
                isNextTransferDue: false,
                isCompleteAcknowledged: false,
                state: MigrationState.requiresAttention(AttentionReason.invalidTransfer(transferId: "t1")),
                expected: MigrationReentryRoute.recovery(isExpired: false)
            ),
            Row(
                name: "2: statusResume",
                isIronwoodActivated: true,
                hasInvalid: false,
                hasOverdue: true,
                isManualDelivery: false,
                isNextTransferDue: false,
                isCompleteAcknowledged: false,
                state: MigrationState.inProgress(progress),
                expected: MigrationReentryRoute.statusResume
            ),
            Row(
                name: "3: reviewManual",
                isIronwoodActivated: true,
                hasInvalid: false,
                hasOverdue: false,
                isManualDelivery: true,
                isNextTransferDue: true,
                isCompleteAcknowledged: false,
                state: MigrationState.inProgress(progress),
                expected: MigrationReentryRoute.reviewManual(step: 2, total: 4)
            ),
            Row(
                name: "4: statusProgress",
                isIronwoodActivated: true,
                hasInvalid: false,
                hasOverdue: false,
                isManualDelivery: false,
                isNextTransferDue: false,
                isCompleteAcknowledged: false,
                state: MigrationState.inProgress(progress),
                expected: MigrationReentryRoute.statusProgress
            ),
            Row(
                name: "5: complete",
                isIronwoodActivated: true,
                hasInvalid: false,
                hasOverdue: false,
                isManualDelivery: false,
                isNextTransferDue: false,
                isCompleteAcknowledged: false,
                state: MigrationState.complete,
                expected: MigrationReentryRoute.complete
            ),
            Row(
                name: "6: noteSplitProgress",
                isIronwoodActivated: true,
                hasInvalid: false,
                hasOverdue: false,
                isManualDelivery: false,
                isNextTransferDue: false,
                isCompleteAcknowledged: false,
                state: MigrationState.splitPendingConfirmation,
                expected: MigrationReentryRoute.noteSplitProgress
            ),
            Row(
                name: "7: entry",
                isIronwoodActivated: true,
                hasInvalid: false,
                hasOverdue: false,
                isManualDelivery: false,
                isNextTransferDue: false,
                isCompleteAcknowledged: false,
                state: MigrationState.notStarted,
                expected: MigrationReentryRoute.entry
            )
        ]

        for row in rows {
            let route = MigrationDerivations.reentryRoute(
                isIronwoodActivated: row.isIronwoodActivated,
                state: row.state,
                hasInvalid: row.hasInvalid,
                hasOverdue: row.hasOverdue,
                isManualDelivery: row.isManualDelivery,
                isNextTransferDue: row.isNextTransferDue,
                isCompleteAcknowledged: row.isCompleteAcknowledged,
                progress: progress
            )

            #expect(route == row.expected, "Row \(row.name) expected \(row.expected) but got \(route)")
        }
    }

    // MARK: - Gate: MigrationGateStorage

    @Test func gateAllowedByDefault() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testMigrationGateAllowedByDefault"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testMigrationGateAllowedByDefault") }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(storage.sendGate(now: now) == MigrationSendGate.allowed)
    }

    @Test func gateSyncRequiredWhilePending() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testMigrationGateSyncRequiredWhilePending"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testMigrationGateSyncRequiredWhilePending") }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        let now = Date(timeIntervalSince1970: 1_000_000)

        storage.markSyncRequired()

        #expect(storage.sendGate(now: now) == MigrationSendGate.syncRequired)
    }

    @Test func gateWaitUntilTenMinutesAfterSyncCompletion() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testMigrationGateWaitUntilTenMinutesAfterSyncCompletion"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testMigrationGateWaitUntilTenMinutesAfterSyncCompletion") }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        let syncCompletedAt = Date(timeIntervalSince1970: 1_000_000)

        storage.markSyncRequired()
        storage.recordSyncCompletion(at: syncCompletedAt)

        let justAfterCompletion = syncCompletedAt.addingTimeInterval(1)
        guard case let MigrationSendGate.waitUntil(gateUntil) = storage.sendGate(now: justAfterCompletion) else {
            Issue.record("Expected .waitUntil right after sync completion")
            return
        }

        #expect(gateUntil == syncCompletedAt.addingTimeInterval(10 * 60))
    }

    @Test func gateTransitionsToAllowedAfterTenMinutesElapse() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testMigrationGateTransitionsToAllowedAfterTenMinutesElapse"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer {
            userDefaults.removePersistentDomain(forName: "testMigrationGateTransitionsToAllowedAfterTenMinutesElapse")
        }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        let syncCompletedAt = Date(timeIntervalSince1970: 1_000_000)

        storage.markSyncRequired()
        storage.recordSyncCompletion(at: syncCompletedAt)

        let exactlyAtGate = syncCompletedAt.addingTimeInterval(10 * 60)
        #expect(storage.sendGate(now: exactlyAtGate) == MigrationSendGate.allowed)

        let wellAfterGate = syncCompletedAt.addingTimeInterval(20 * 60)
        #expect(storage.sendGate(now: wellAfterGate) == MigrationSendGate.allowed)
    }

    @Test func gateFullSyncRequiredToWaitUntilToAllowedTransition() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testMigrationGateFullTransition"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testMigrationGateFullTransition") }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        let t0 = Date(timeIntervalSince1970: 2_000_000)

        // Before any sync requirement is observed: allowed.
        #expect(storage.sendGate(now: t0) == MigrationSendGate.allowed)

        // Sync becomes required: CTA disabled outright.
        storage.markSyncRequired()
        #expect(storage.sendGate(now: t0) == MigrationSendGate.syncRequired)

        // Sync completes: 10-minute countdown starts.
        storage.recordSyncCompletion(at: t0)
        guard case .waitUntil = storage.sendGate(now: t0.addingTimeInterval(60)) else {
            Issue.record("Expected .waitUntil 1 minute after sync completion")
            return
        }

        // 10 minutes elapse: allowed again.
        #expect(storage.sendGate(now: t0.addingTimeInterval(10 * 60 + 1)) == MigrationSendGate.allowed)
    }

    @Test func gateStatePersistsAcrossStorageInstancesUsingTheSameSuite() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testMigrationGatePersistsAcrossInstances"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testMigrationGatePersistsAcrossInstances") }

        let syncCompletedAt = Date(timeIntervalSince1970: 3_000_000)

        let firstStorage = MigrationGateStorage(userDefaults: userDefaults)
        firstStorage.markSyncRequired()
        firstStorage.recordSyncCompletion(at: syncCompletedAt)

        // A fresh instance over the same UserDefaults suite (simulating relaunch) must observe
        // the persisted gate, not reset to `.allowed` — the whole point of persisting
        // `migrationSyncGateUntil` is that a relaunch cannot dodge the send-side gate.
        let secondStorage = MigrationGateStorage(userDefaults: userDefaults)
        guard case let MigrationSendGate.waitUntil(gateUntil) = secondStorage.sendGate(
            now: syncCompletedAt.addingTimeInterval(1)
        ) else {
            Issue.record("Expected persisted .waitUntil to survive a fresh MigrationGateStorage instance")
            return
        }

        #expect(gateUntil == syncCompletedAt.addingTimeInterval(10 * 60))
    }

    @Test func recordMigrationBroadcastPersistsTimestamp() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testRecordMigrationBroadcastPersistsTimestamp"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testRecordMigrationBroadcastPersistsTimestamp") }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        let broadcastAt = Date(timeIntervalSince1970: 4_000_000)

        storage.recordMigrationBroadcast(at: broadcastAt)

        let stored = userDefaults.object(forKey: .migrationLastBroadcastAt) as? Double
        #expect(stored == broadcastAt.timeIntervalSince1970)
    }

    @Test func syncDeferredForTenMinutesAfterBroadcast() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testSyncDeferredForTenMinutesAfterBroadcast"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testSyncDeferredForTenMinutesAfterBroadcast") }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        let broadcastAt = Date(timeIntervalSince1970: 4_000_000)

        // No broadcast recorded yet -> never deferred.
        #expect(storage.isSyncDeferredAfterBroadcast(now: broadcastAt) == false)

        storage.recordMigrationBroadcast(at: broadcastAt)

        // Deferred strictly within the 10-minute window after the broadcast, allowed at/after it
        // (the sync side of the feature spec section 8.2 separation, consumed by MOB-1467).
        #expect(storage.isSyncDeferredAfterBroadcast(now: broadcastAt.addingTimeInterval(1)) == true)
        #expect(storage.isSyncDeferredAfterBroadcast(now: broadcastAt.addingTimeInterval(10 * 60 - 1)) == true)
        #expect(storage.isSyncDeferredAfterBroadcast(now: broadcastAt.addingTimeInterval(10 * 60)) == false)
    }

    // MARK: - Persistence: mode / manual delivery / network privacy / acknowledge

    @Test func migrationModePersistenceRoundTrip() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testMigrationModePersistenceRoundTrip"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testMigrationModePersistenceRoundTrip") }

        let storage = MigrationGateStorage(userDefaults: userDefaults)

        #expect(storage.migrationMode() == nil)

        storage.setMigrationMode(MigrationMode.immediate)
        #expect(storage.migrationMode() == MigrationMode.immediate)

        storage.setMigrationMode(MigrationMode.privateScheduled)
        #expect(storage.migrationMode() == MigrationMode.privateScheduled)
    }

    @Test func manualDeliveryPersistenceRoundTrip() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testManualDeliveryPersistenceRoundTrip"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testManualDeliveryPersistenceRoundTrip") }

        let storage = MigrationGateStorage(userDefaults: userDefaults)

        #expect(storage.isManualDelivery() == false)

        storage.setManualDelivery(true)
        #expect(storage.isManualDelivery() == true)

        storage.setManualDelivery(false)
        #expect(storage.isManualDelivery() == false)
    }

    @Test func networkPrivacyOptionsPersistenceRoundTrip() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testNetworkPrivacyOptionsPersistenceRoundTrip"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testNetworkPrivacyOptionsPersistenceRoundTrip") }

        let storage = MigrationGateStorage(userDefaults: userDefaults)

        #expect(storage.networkPrivacyOptions() == NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil))

        let options = NetworkPrivacyOptions(useTor: true, submissionEndpoint: "https://example.com:9067")
        storage.setNetworkPrivacyOptions(options)
        #expect(storage.networkPrivacyOptions() == options)
    }

    @Test func completeAcknowledgedPersistenceRoundTrip() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testCompleteAcknowledgedPersistenceRoundTrip"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testCompleteAcknowledgedPersistenceRoundTrip") }

        let storage = MigrationGateStorage(userDefaults: userDefaults)

        #expect(storage.isCompleteAcknowledged() == false)

        storage.acknowledgeComplete()
        #expect(storage.isCompleteAcknowledged() == true)

        storage.clearAcknowledgedComplete()
        #expect(storage.isCompleteAcknowledged() == false)
    }

    // MARK: - reconcile(): stale-acknowledge reset
    //
    // These two exercise the real `MigrationManagerImpl.reconcile()` (MigrationManagerLiveKey.swift)
    // against an isolated `UserDefaults` suite via the Impl's injectable `gateStorage` seam, with
    // `getMigrationState` stubbed through `withDependencies` — the stale-acknowledge reset must
    // clear the flag for any non-`.complete` state and preserve it while `.complete`.

    @Test func reconcileClearsAcknowledgedFlagWhenStateIsNotComplete() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testReconcileClearsAcknowledgedFlagWhenStateIsNotComplete"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer {
            userDefaults.removePersistentDomain(forName: "testReconcileClearsAcknowledgedFlagWhenStateIsNotComplete")
        }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        storage.acknowledgeComplete()
        #expect(storage.isCompleteAcknowledged() == true)

        withDependencies {
            // MOB-1483: `reconcile()` now gates on `isIronwoodActivated()` first — open the gate
            // (tip past the ambient `ZcashSDKEnvironment.testValue` activation height) so this
            // test still exercises the stale-acknowledge reset it's actually about. `latestState`
            // is a `let` on the client, so it must be set through the `mocked(latestState:)` base.
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                latestState: {
                    var state = SynchronizerState.zero
                    state.latestBlockHeight = 5_000_000
                    return state
                }
            )
            $0.sdkSynchronizer.getMigrationState = {
                MigrationState.inProgress(
                    MigrationProgress(completedTransfers: 1, totalTransfers: 5, remainingOrchard: Zatoshi(1), nextTransferReadyAtHeight: nil)
                )
            }
        } operation: {
            let impl = MigrationManagerImpl(gateStorage: storage)
            impl.reconcile()
        }

        #expect(storage.isCompleteAcknowledged() == false)
    }

    @Test func reconcileKeepsAcknowledgedFlagWhenStateIsComplete() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testReconcileKeepsAcknowledgedFlagWhenStateIsComplete"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testReconcileKeepsAcknowledgedFlagWhenStateIsComplete") }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        storage.acknowledgeComplete()
        #expect(storage.isCompleteAcknowledged() == true)

        withDependencies {
            // MOB-1483: open the gate — see the comment in
            // `reconcileClearsAcknowledgedFlagWhenStateIsNotComplete` above.
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                latestState: {
                    var state = SynchronizerState.zero
                    state.latestBlockHeight = 5_000_000
                    return state
                }
            )
            $0.sdkSynchronizer.getMigrationState = { MigrationState.complete }
        } operation: {
            let impl = MigrationManagerImpl(gateStorage: storage)
            impl.reconcile()
        }

        #expect(storage.isCompleteAcknowledged() == true)
    }

    // MARK: - isIronwoodActivated(): MOB-1483 activation gate
    //
    // `MigrationManagerImpl.isIronwoodActivated() == tip > 0 && tip >= ironwoodActivationHeight`.
    // `tip > 0` is the fail-safe sentinel: an unsynced cached tip (0, before the first server
    // round-trip) must read as "not activated," independent of whatever height is configured.

    @Test func isIronwoodActivatedFalseWhenTipIsUnknown() {
        let result = withDependencies {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked() // `mocked()` keeps `latestState` at `.zero` — tip == 0: unsynced
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { 0 } // even a trivially-met height must not matter
        } operation: {
            MigrationManagerImpl().isIronwoodActivated()
        }

        #expect(result == false)
    }

    @Test func isIronwoodActivatedFalseWhenTipIsBelowActivationHeight() {
        let result = withDependencies {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                latestState: {
                    var state = SynchronizerState.zero
                    state.latestBlockHeight = 99
                    return state
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { 100 }
        } operation: {
            MigrationManagerImpl().isIronwoodActivated()
        }

        #expect(result == false)
    }

    @Test func isIronwoodActivatedTrueAtExactActivationHeight() {
        let result = withDependencies {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                latestState: {
                    var state = SynchronizerState.zero
                    state.latestBlockHeight = 100
                    return state
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { 100 }
        } operation: {
            MigrationManagerImpl().isIronwoodActivated()
        }

        #expect(result == true)
    }

    @Test func isIronwoodActivatedTrueWhenTipIsPastActivationHeight() {
        let result = withDependencies {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                latestState: {
                    var state = SynchronizerState.zero
                    state.latestBlockHeight = 500
                    return state
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { 100 }
        } operation: {
            MigrationManagerImpl().isIronwoodActivated()
        }

        #expect(result == true)
    }

    // MARK: - reconcile(): Ironwood activation gate (MOB-1483)
    //
    // `reconcile()` must skip `initializeMigrationPostUpgrade()` and the acknowledged-flag
    // maintenance entirely while Ironwood is not activated on the current network — there is
    // nothing to reconcile pre-activation. `initializeMigrationPostUpgrade` / `getMigrationState`
    // are wrapped in `LockIsolated<Int>` call counters (the `RootMigrationBackgroundTests` spy
    // precedent) asserted `== 0`; `gateStorage`'s persisted flag is asserted unchanged as evidence
    // `clearAcknowledgedComplete()` was never reached either. (`sdkSynchronizer.latestState()`
    // itself *is* called — that's the gate check.)

    @Test func reconcileSkipsSDKAndStorageCallsWhenIronwoodIsNotActivated() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testReconcileSkipsSDKAndStorageCallsWhenIronwoodIsNotActivated"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer {
            userDefaults.removePersistentDomain(forName: "testReconcileSkipsSDKAndStorageCallsWhenIronwoodIsNotActivated")
        }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        storage.acknowledgeComplete()
        #expect(storage.isCompleteAcknowledged() == true)

        let initializeCalls = LockIsolated<Int>(0)
        let getMigrationStateCalls = LockIsolated<Int>(0)

        withDependencies {
            // Tip 0 == "no server round-trip yet": the gate's own fail-safe sentinel, independent
            // of whatever height `zcashSDKEnvironment.ironwoodActivationHeight()` reports.
            // `mocked()` keeps `latestState` at `.zero` (it's a `let` on the client).
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked()
            $0.sdkSynchronizer.initializeMigrationPostUpgrade = { initializeCalls.withValue { $0 += 1 } }
            $0.sdkSynchronizer.getMigrationState = {
                getMigrationStateCalls.withValue { $0 += 1 }
                return MigrationState.notStarted
            }
        } operation: {
            let impl = MigrationManagerImpl(gateStorage: storage)
            impl.reconcile()
        }

        #expect(initializeCalls.withValue { $0 } == 0)
        #expect(getMigrationStateCalls.withValue { $0 } == 0)
        // Unchanged (still true): `clearAcknowledgedComplete()` was never reached either.
        #expect(storage.isCompleteAcknowledged() == true)
    }

    @Test func reconcileSkipsSDKAndStorageCallsWhenTipIsBelowActivationHeight() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testReconcileSkipsSDKAndStorageCallsWhenTipIsBelowActivationHeight"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer {
            userDefaults.removePersistentDomain(forName: "testReconcileSkipsSDKAndStorageCallsWhenTipIsBelowActivationHeight")
        }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        storage.acknowledgeComplete()
        #expect(storage.isCompleteAcknowledged() == true)

        let initializeCalls = LockIsolated<Int>(0)
        let getMigrationStateCalls = LockIsolated<Int>(0)

        withDependencies {
            // A known, synced tip that simply hasn't reached activation yet — distinct from the
            // tip == 0 sentinel case above, exercising the actual height comparison.
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                latestState: {
                    var state = SynchronizerState.zero
                    state.latestBlockHeight = 99
                    return state
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { 100 }
            $0.sdkSynchronizer.initializeMigrationPostUpgrade = { initializeCalls.withValue { $0 += 1 } }
            $0.sdkSynchronizer.getMigrationState = {
                getMigrationStateCalls.withValue { $0 += 1 }
                return MigrationState.notStarted
            }
        } operation: {
            let impl = MigrationManagerImpl(gateStorage: storage)
            impl.reconcile()
        }

        #expect(initializeCalls.withValue { $0 } == 0)
        #expect(getMigrationStateCalls.withValue { $0 } == 0)
        #expect(storage.isCompleteAcknowledged() == true)
    }
}
