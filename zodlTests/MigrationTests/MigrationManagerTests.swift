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
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized)
struct MigrationManagerTests {
    // MARK: - bannerVariant

    @Test func notStartedWithPositiveBalanceIsRequired() {
        let variant = MigrationDerivations.bannerVariant(
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
        // is stale-true from a previous migration (that reset is `reconcile()`'s job, exercised
        // separately below via `MigrationGateStorage`/manager-level tests, not this pure table).
        let variant = MigrationDerivations.bannerVariant(
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

    // MARK: - reentryRoute

    @Test func hasInvalidTransfersWinsOverEverythingElse() {
        let progress = MigrationProgress(
            completedTransfers: 1,
            totalTransfers: 2,
            remainingOrchard: Zatoshi.zero,
            nextTransferReadyAtHeight: nil
        )

        let route = MigrationDerivations.reentryRoute(
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

    @Test func invalidTransferWithTransferExpiredAttentionReasonIsExpiredRecovery() {
        let route = MigrationDerivations.reentryRoute(
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
            Row(
                name: "1: recovery",
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
}
