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
@preconcurrency import Combine
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
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

    // MOB-1496: the SDK's `MigrationAttentionReason` has no `.transferStalled` case — "stalled" is
    // now derived from `hasOverdue` on an `.inProgress` state (see `bannerVariant`'s doc), checked
    // BEFORE the manual-ready check below.
    @Test func inProgressWithHasOverdueIsTransferWaiting() {
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
            hasOverdue: true,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.transferWaiting(number: 3))
    }

    @Test func hasOverdueWinsOverManualReadyForBannerVariant() {
        let progress = MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 5,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: 100
        )

        // Maximally-offering input for `.transferReady` (manual + due) — `hasOverdue` must still
        // win, mirroring `reentryRoute`'s existing `hasOverdue`-before-manual precedence.
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.inProgress(progress),
            hasInvalid: false,
            hasOverdue: true,
            isManualDelivery: true,
            isNextTransferDue: true,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.transferWaiting(number: 3))
    }

    @Test func notStartedIgnoresHasOverdueEvenWhenTrue() {
        // `hasOverdue` is only consulted inside the `.inProgress` switch case — states outside it
        // must behave identically regardless of its value.
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.notStarted,
            hasInvalid: false,
            hasOverdue: true,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi(1),
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.required)
    }

    @Test func completeIgnoresHasOverdueEvenWhenTrue() {
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.complete,
            hasInvalid: false,
            hasOverdue: true,
            isManualDelivery: false,
            isNextTransferDue: false,
            orchardBalance: Zatoshi.zero,
            isCompleteAcknowledged: false,
            transferRows: []
        )

        #expect(variant == MigrationBannerVariant.complete)
    }

    @Test func requiresAttentionInvalidTransferIsUpdatePlan() {
        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: MigrationState.requiresAttention(MigrationAttentionReason.invalidTransfer(transferId: "t1")),
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
            state: MigrationState.requiresAttention(MigrationAttentionReason.transferExpired),
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
            state: MigrationState.requiresAttention(MigrationAttentionReason.transferExpired),
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
            state: MigrationState.requiresAttention(MigrationAttentionReason.transferExpired),
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
            state: MigrationState.requiresAttention(MigrationAttentionReason.transferExpired),
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
            state: MigrationState.requiresAttention(MigrationAttentionReason.invalidTransfer(transferId: "t1")),
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
                state: MigrationState.requiresAttention(MigrationAttentionReason.invalidTransfer(transferId: "t1")),
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
                state: MigrationState.requiresAttention(MigrationAttentionReason.invalidTransfer(transferId: "t1")),
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

    /// MOB-1496: the SDK's `MigrationNetworkPrivacyOptions` isn't `Codable` (it carries a
    /// `LightWalletEndpoint`) — only the persisted `useTor` choice lives on `MigrationGateStorage`
    /// now (`isTorEnabledForMigration`/`setTorEnabledForMigration`); the endpoint half is
    /// materialized at read time by `MigrationManagerImpl.networkPrivacyOptions()`, not persisted.
    @Test func torEnabledForMigrationPersistenceRoundTrip() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testTorEnabledForMigrationPersistenceRoundTrip"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testTorEnabledForMigrationPersistenceRoundTrip") }

        let storage = MigrationGateStorage(userDefaults: userDefaults)

        #expect(storage.isTorEnabledForMigration() == false)

        storage.setTorEnabledForMigration(true)
        #expect(storage.isTorEnabledForMigration() == true)

        storage.setTorEnabledForMigration(false)
        #expect(storage.isTorEnabledForMigration() == false)
    }

    /// MOB-1487/MOB-1496: "Lock balance" persistence — relocated onto `MigrationGateStorage` from
    /// the (inert, pre-real-SDK) `SDKSynchronizerClient` stub.
    @Test func dustLockedPersistenceRoundTrip() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testDustLockedPersistenceRoundTrip"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testDustLockedPersistenceRoundTrip") }

        let storage = MigrationGateStorage(userDefaults: userDefaults)

        #expect(storage.isDustLocked() == false)

        storage.setDustLocked(true)
        #expect(storage.isDustLocked() == true)

        storage.setDustLocked(false)
        #expect(storage.isDustLocked() == false)
    }

    @Test func resetPersistedFlagsClearsDustLockedAlongWithEveryOtherFlag() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testResetPersistedFlagsClearsDustLockedAlongWithEveryOtherFlag"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer {
            userDefaults.removePersistentDomain(forName: "testResetPersistedFlagsClearsDustLockedAlongWithEveryOtherFlag")
        }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        storage.setMigrationMode(MigrationMode.immediate)
        storage.setManualDelivery(true)
        storage.setTorEnabledForMigration(true)
        storage.acknowledgeComplete()
        storage.setDustLocked(true)
        storage.recordMigrationBroadcast(at: Date(timeIntervalSince1970: 5_000_000))

        storage.resetPersistedFlags()

        #expect(storage.migrationMode() == nil)
        #expect(storage.isManualDelivery() == false)
        #expect(storage.isTorEnabledForMigration() == false)
        #expect(storage.isCompleteAcknowledged() == false)
        #expect(storage.isDustLocked() == false)
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
    // clear the flag for any non-`.complete` state and preserve it while `.complete`. MOB-1496:
    // `reconcile()` is now `async` and needs a selected account (`@Shared(.inMemory(...))`) to
    // resolve anything at all — with no Keystone account in `walletAccounts`, only that one account
    // is refreshed, keeping these tests' single-account shape.

    @Test func reconcileClearsAcknowledgedFlagWhenStateIsNotComplete() async throws {
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

        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        let account = WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 1, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
        $selectedWalletAccount.withLock { $0 = account }
        $walletAccounts.withLock { $0 = [account] }

        await withDependencies {
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
            $0.sdkSynchronizer.getMigrationState = { _ in
                MigrationState.inProgress(
                    MigrationProgress(completedTransfers: 1, totalTransfers: 5, remainingOrchard: Zatoshi(1), nextTransferReadyAtHeight: nil)
                )
            }
        } operation: {
            let impl = MigrationManagerImpl(gateStorage: storage)
            await impl.reconcile()
        }

        #expect(storage.isCompleteAcknowledged() == false)
    }

    @Test func reconcileKeepsAcknowledgedFlagWhenStateIsComplete() async throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testReconcileKeepsAcknowledgedFlagWhenStateIsComplete"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: "testReconcileKeepsAcknowledgedFlagWhenStateIsComplete") }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        storage.acknowledgeComplete()
        #expect(storage.isCompleteAcknowledged() == true)

        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        let account = WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 2, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
        $selectedWalletAccount.withLock { $0 = account }
        $walletAccounts.withLock { $0 = [account] }

        await withDependencies {
            // MOB-1483: open the gate — see the comment in
            // `reconcileClearsAcknowledgedFlagWhenStateIsNotComplete` above.
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                latestState: {
                    var state = SynchronizerState.zero
                    state.latestBlockHeight = 5_000_000
                    return state
                }
            )
            $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.complete }
        } operation: {
            let impl = MigrationManagerImpl(gateStorage: storage)
            await impl.reconcile()
        }

        #expect(storage.isCompleteAcknowledged() == true)
    }

    // MARK: - stateEvents(): emits only on a reconcile-observed change

    /// `stateEvents(accountUUID:)` is backed by a `CurrentValueSubject` seeded `.notStarted`
    /// (`MigrationManagerImpl.subject(for:)`), and `reconcile()` only `.send()`s into it when a
    /// fresh read differs from the subject's last-pushed value — MOB-1496 (W2 emit-fix): that
    /// comparison now covers BOTH `getMigrationState` (the subject's own `.value`) AND
    /// `orchardBalanceToMigrate(accountUUID) > 0` (tracked beside it — see `pushStateIfChanged`'s
    /// doc). A brand-new `CurrentValueSubject` subscriber immediately replays its current value, so
    /// the first collected element is always the `.notStarted` seed. Five `reconcile()` calls drive
    /// every combination: state-only change emits, an identical re-read emits nothing, a second
    /// state change emits, a BALANCE-ONLY flip (state repeats) still emits, and a final call where
    /// neither changed emits nothing.
    @Test func stateEventsEmitsOnStateOrBalanceChangeAndNotOnIdenticalReRead() async throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testStateEventsEmitsOnStateOrBalanceChangeAndNotOnIdenticalReRead"),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer {
            userDefaults.removePersistentDomain(forName: "testStateEventsEmitsOnStateOrBalanceChangeAndNotOnIdenticalReRead")
        }

        let storage = MigrationGateStorage(userDefaults: userDefaults)

        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        let account = WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 6, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
        $selectedWalletAccount.withLock { $0 = account }
        $walletAccounts.withLock { $0 = [account] }

        let progress = MigrationProgress(
            completedTransfers: 1, totalTransfers: 5, remainingOrchard: Zatoshi(1), nextTransferReadyAtHeight: nil
        )
        let currentState = LockIsolated<MigrationState>(MigrationState.inProgress(progress))
        let currentOrchardBalance = LockIsolated<Zatoshi>(Zatoshi.zero)

        await withDependencies {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                latestState: {
                    var state = SynchronizerState.zero
                    state.latestBlockHeight = 5_000_000
                    return state
                },
                getAccountsBalances: {
                    [
                        account.id: AccountBalance(
                            saplingBalance: PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
                            orchardBalance: PoolBalance(
                                spendableValue: currentOrchardBalance.value,
                                changePendingConfirmation: .zero,
                                valuePendingSpendability: .zero
                            ),
                            unshielded: .zero
                        )
                    ]
                }
            )
            $0.sdkSynchronizer.getMigrationState = { _ in currentState.value }
        } operation: {
            let impl = MigrationManagerImpl(gateStorage: storage)
            let collected = LockIsolated<[MigrationState]>([])
            let cancellable = impl.stateEvents(accountUUID: account.id).sink { state in
                collected.withValue { $0.append(state) }
            }

            // 1st reconcile: notStarted (seed) -> inProgress is a genuine change -> emits.
            await impl.reconcile()
            // 2nd reconcile: same inProgress value re-read, balance still zero -> no emission.
            await impl.reconcile()
            // 3rd reconcile: flips to complete -> a second genuine change -> emits.
            currentState.setValue(MigrationState.complete)
            await impl.reconcile()
            // 4th reconcile: state repeats (.complete), but the balance-to-migrate flag flips
            // false -> true -> emits again (MOB-1496 W2 emit-fix), re-delivering the same state.
            currentOrchardBalance.setValue(Zatoshi(1))
            await impl.reconcile()
            // 5th reconcile: neither state nor balance changed -> no further emission.
            await impl.reconcile()

            #expect(collected.value == [
                MigrationState.notStarted,
                MigrationState.inProgress(progress),
                MigrationState.complete,
                MigrationState.complete
            ])

            cancellable.cancel()
        }
    }

    // MARK: - MOB-1496 (W2): persisted-schedule clearing on run-end / reset / stale reconcile

    /// `reconcile()` clears a persisted committed schedule the moment it observes `.notStarted`
    /// for an account that still has one — the engine is authoritative, so a stale payload (e.g.
    /// from an abandoned or reset run) must not keep rendering rows for a run the engine no longer
    /// knows about.
    @Test func reconcileClearsStalePersistedScheduleWhenStateIsNotStarted() async throws {
        let gateSuiteName = "testReconcileClearsStalePersistedScheduleWhenStateIsNotStartedGate"
        let scheduleSuiteName = "testReconcileClearsStalePersistedScheduleWhenStateIsNotStartedSchedule"
        let gateUserDefaults = try #require(UserDefaults(suiteName: gateSuiteName))
        let scheduleUserDefaults = try #require(UserDefaults(suiteName: scheduleSuiteName))
        defer {
            gateUserDefaults.removePersistentDomain(forName: gateSuiteName)
            scheduleUserDefaults.removePersistentDomain(forName: scheduleSuiteName)
        }

        let gateStorage = MigrationGateStorage(userDefaults: gateUserDefaults)
        let scheduleStorage = MigrationScheduleStorage(userDefaults: scheduleUserDefaults)

        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        let account = WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 20, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
        $selectedWalletAccount.withLock { $0 = account }
        $walletAccounts.withLock { $0 = [account] }

        let schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(100), anchorHeight: 10, nextExecutableAfterHeight: 10, expiryHeight: 20)],
            estimatedDurationHours: 6
        )
        scheduleStorage.recordCommittedSchedule(schedule, for: account.id, now: Date())
        #expect(scheduleStorage.hasStoredPayload(for: account.id) == true)

        await withDependencies {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                latestState: {
                    var state = SynchronizerState.zero
                    state.latestBlockHeight = 5_000_000
                    return state
                }
            )
            $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.notStarted }
        } operation: {
            let impl = MigrationManagerImpl(gateStorage: gateStorage, scheduleStorage: scheduleStorage)
            await impl.reconcile()
        }

        #expect(scheduleStorage.hasStoredPayload(for: account.id) == false)
    }

    /// A genuinely `.notStarted` account with NO stored payload is untouched (nothing to clear) —
    /// exercised so the stale-clear branch reads as a targeted fix, not a blanket per-reconcile
    /// write.
    @Test func reconcileWithNotStartedStateAndNoStoredPayloadDoesNothing() async throws {
        let gateSuiteName = "testReconcileWithNotStartedStateAndNoStoredPayloadDoesNothingGate"
        let scheduleSuiteName = "testReconcileWithNotStartedStateAndNoStoredPayloadDoesNothingSchedule"
        let gateUserDefaults = try #require(UserDefaults(suiteName: gateSuiteName))
        let scheduleUserDefaults = try #require(UserDefaults(suiteName: scheduleSuiteName))
        defer {
            gateUserDefaults.removePersistentDomain(forName: gateSuiteName)
            scheduleUserDefaults.removePersistentDomain(forName: scheduleSuiteName)
        }

        let gateStorage = MigrationGateStorage(userDefaults: gateUserDefaults)
        let scheduleStorage = MigrationScheduleStorage(userDefaults: scheduleUserDefaults)

        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        let account = WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 21, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
        $selectedWalletAccount.withLock { $0 = account }
        $walletAccounts.withLock { $0 = [account] }

        await withDependencies {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                latestState: {
                    var state = SynchronizerState.zero
                    state.latestBlockHeight = 5_000_000
                    return state
                }
            )
            $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.notStarted }
        } operation: {
            let impl = MigrationManagerImpl(gateStorage: gateStorage, scheduleStorage: scheduleStorage)
            await impl.reconcile()
        }

        #expect(scheduleStorage.hasStoredPayload(for: account.id) == false)
    }

    /// `acknowledgeComplete()` bundles the existing wallet-wide flag with clearing the SELECTED
    /// account's persisted schedule — the run Migration Complete was showing has ended.
    @Test func acknowledgeCompleteClearsTheSelectedAccountsPersistedSchedule() throws {
        let gateSuiteName = "testAcknowledgeCompleteClearsTheSelectedAccountsPersistedScheduleGate"
        let scheduleSuiteName = "testAcknowledgeCompleteClearsTheSelectedAccountsPersistedScheduleSchedule"
        let gateUserDefaults = try #require(UserDefaults(suiteName: gateSuiteName))
        let scheduleUserDefaults = try #require(UserDefaults(suiteName: scheduleSuiteName))
        defer {
            gateUserDefaults.removePersistentDomain(forName: gateSuiteName)
            scheduleUserDefaults.removePersistentDomain(forName: scheduleSuiteName)
        }

        let gateStorage = MigrationGateStorage(userDefaults: gateUserDefaults)
        let scheduleStorage = MigrationScheduleStorage(userDefaults: scheduleUserDefaults)

        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        let account = WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 22, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
        $selectedWalletAccount.withLock { $0 = account }

        let schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(100), anchorHeight: 10, nextExecutableAfterHeight: 10, expiryHeight: 20)],
            estimatedDurationHours: 6
        )
        scheduleStorage.recordCommittedSchedule(schedule, for: account.id, now: Date())

        let impl = MigrationManagerImpl(gateStorage: gateStorage, scheduleStorage: scheduleStorage)
        impl.acknowledgeComplete()

        #expect(gateStorage.isCompleteAcknowledged() == true)
        #expect(scheduleStorage.hasStoredPayload(for: account.id) == false)
    }

    /// `resetPersistedFlags()` (the migration SDK simulator's debug "Reset app migration flags"
    /// control) clears every KNOWN account's persisted schedule, not just the selected one.
    @Test func resetPersistedFlagsClearsEveryKnownAccountsPersistedSchedule() throws {
        let gateSuiteName = "testResetPersistedFlagsClearsEveryKnownAccountsPersistedScheduleGate"
        let scheduleSuiteName = "testResetPersistedFlagsClearsEveryKnownAccountsPersistedScheduleSchedule"
        let gateUserDefaults = try #require(UserDefaults(suiteName: gateSuiteName))
        let scheduleUserDefaults = try #require(UserDefaults(suiteName: scheduleSuiteName))
        defer {
            gateUserDefaults.removePersistentDomain(forName: gateSuiteName)
            scheduleUserDefaults.removePersistentDomain(forName: scheduleSuiteName)
        }

        let gateStorage = MigrationGateStorage(userDefaults: gateUserDefaults)
        let scheduleStorage = MigrationScheduleStorage(userDefaults: scheduleUserDefaults)

        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        let selected = WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 23, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
        let keystone = WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 24, count: 16)),
                name: "Keystone",
                keySource: String(localizable: .accountsKeystone).lowercased(),
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
        $selectedWalletAccount.withLock { $0 = selected }
        $walletAccounts.withLock { $0 = [selected, keystone] }

        let schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(100), anchorHeight: 10, nextExecutableAfterHeight: 10, expiryHeight: 20)],
            estimatedDurationHours: 6
        )
        scheduleStorage.recordCommittedSchedule(schedule, for: selected.id, now: Date())
        scheduleStorage.recordCommittedSchedule(schedule, for: keystone.id, now: Date())

        let impl = MigrationManagerImpl(gateStorage: gateStorage, scheduleStorage: scheduleStorage)
        impl.resetPersistedFlags()

        #expect(scheduleStorage.hasStoredPayload(for: selected.id) == false)
        #expect(scheduleStorage.hasStoredPayload(for: keystone.id) == false)
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
    // `reconcile()` must skip `getMigrationState` entirely (and, with it, the acknowledged-flag
    // maintenance) while Ironwood is not activated on the current network — there is nothing to
    // reconcile pre-activation. MOB-1496: the pre-real-SDK `initializeMigrationPostUpgrade` member
    // this used to also assert on is gone — the real SDK's migration state machine bootstraps
    // itself, no app-side "initialize" call exists any more. `getMigrationState` is wrapped in a
    // `LockIsolated<Int>` call counter (the `RootMigrationBackgroundTests` spy precedent) asserted
    // `== 0`; `gateStorage`'s persisted flag is asserted unchanged as evidence
    // `clearAcknowledgedComplete()` was never reached either. (`sdkSynchronizer.latestState()`
    // itself *is* called — that's the gate check. No selected account is needed: the gate's early
    // `return` fires before account resolution.)

    @Test func reconcileSkipsSDKAndStorageCallsWhenIronwoodIsNotActivated() async throws {
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

        let getMigrationStateCalls = LockIsolated<Int>(0)

        await withDependencies {
            // Tip 0 == "no server round-trip yet": the gate's own fail-safe sentinel, independent
            // of whatever height `zcashSDKEnvironment.ironwoodActivationHeight()` reports.
            // `mocked()` keeps `latestState` at `.zero` (it's a `let` on the client).
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked()
            $0.sdkSynchronizer.getMigrationState = { _ in
                getMigrationStateCalls.withValue { $0 += 1 }
                return MigrationState.notStarted
            }
        } operation: {
            let impl = MigrationManagerImpl(gateStorage: storage)
            await impl.reconcile()
        }

        #expect(getMigrationStateCalls.withValue { $0 } == 0)
        // Unchanged (still true): `clearAcknowledgedComplete()` was never reached either.
        #expect(storage.isCompleteAcknowledged() == true)
    }

    @Test func reconcileSkipsSDKAndStorageCallsWhenTipIsBelowActivationHeight() async throws {
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

        let getMigrationStateCalls = LockIsolated<Int>(0)

        await withDependencies {
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
            $0.sdkSynchronizer.getMigrationState = { _ in
                getMigrationStateCalls.withValue { $0 += 1 }
                return MigrationState.notStarted
            }
        } operation: {
            let impl = MigrationManagerImpl(gateStorage: storage)
            await impl.reconcile()
        }

        #expect(getMigrationStateCalls.withValue { $0 } == 0)
        #expect(storage.isCompleteAcknowledged() == true)
    }
}
