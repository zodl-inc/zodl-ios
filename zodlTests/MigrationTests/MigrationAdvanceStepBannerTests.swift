//
//  MigrationAdvanceStepBannerTests.swift
//  zodlTests
//
//  A15 — the smart-banner audit, made permanent.
//
//  The migration's whole control flow now hangs off ONE engine answer: `next_step()`. Everything the
//  user sees is two hops from it — `MigrationAdvanceStep` → `MigrationState.derive` → `bannerVariant`
//  — and each hop was written and reviewed separately. This suite walks the composed chain for every
//  advance-step case, so the audit is a table that fails when the mapping drifts rather than a
//  paragraph in a board that goes stale.
//
//  Reading these as a table: the left column is what the ENGINE said, the right is what the USER is
//  told. Nothing here asserts an intermediate state — an intermediate that changes while the
//  user-visible answer stays correct is a refactor, not a regression.
//

import Foundation
import Testing
@_spi(Testing) import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationAdvanceStepBannerTests {
    // MARK: - Fixtures

    private static func progress(completed: Int = 1, total: Int = 4, isImmediate: Bool = false) -> MigrationProgress {
        MigrationProgress(
            completedTransfers: completed,
            totalTransfers: total,
            remainingOrchard: Zatoshi(500_000_000),
            nextTransferReadyAtHeight: 3_000_000,
            isImmediate: isImmediate
        )
    }

    private static func status(
        id: UInt32,
        kind: MigrationTransactionStatus.Kind,
        state: MigrationTransactionStatus.State,
        isReady: Bool = false,
        blockedOn: MigrationTransactionStatus.Blocker? = nil,
        dependsOn: [UInt32] = []
    ) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: kind,
            state: state,
            scheduledHeight: 3_000_000,
            expiryHeight: nil,
            isReady: isReady,
            nextAction: isReady ? .broadcast : nil,
            blockedOn: blockedOn,
            dependsOn: dependsOn,
            anchorBoundaryHeight: nil
        )
    }

    /// The full chain, end to end: what the engine reports → what the banner says.
    private static func banner(
        advanceStep: MigrationAdvanceStep?,
        progress: MigrationProgress? = nil,
        statuses: [MigrationTransactionStatus] = [],
        hasInvalid: Bool = false,
        isBroadcastInFlight: Bool = false,
        orchardBalance: Zatoshi = Zatoshi(500_000_000),
        isCompleteAcknowledged: Bool = false,
        transferRows: [MigrationTransferRow] = []
    ) -> MigrationBannerVariant? {
        let state = MigrationState.derive(
            advanceStep: advanceStep,
            progress: progress,
            statuses: statuses,
            hasInvalidTransfers: hasInvalid
        )
        return MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: state,
            orchardBalance: orchardBalance,
            isCompleteAcknowledged: isCompleteAcknowledged,
            isMigrationRemainderPending: false,
            transferRows: transferRows,
            isBroadcastInFlight: isBroadcastInFlight
        )
    }

    // MARK: - No run stored

    @Test func noRunWithABalanceOffersTheMigration() {
        #expect(Self.banner(advanceStep: nil) == .required)
    }

    @Test func noRunAndNoBalanceShowsNothing() {
        #expect(Self.banner(advanceStep: nil, orchardBalance: .zero) == nil)
    }

    /// MOB-1630: below 0.01 ZEC/TAZ (ZIP 318's `MAX_RESIDUAL_VALUE`, the smallest migratable
    /// denomination) the engine can never plan a transfer, so the banner must not offer a
    /// migration it would immediately dead-end.
    @Test func noRunWithOnlyDustShowsNothing() {
        #expect(Self.banner(advanceStep: nil, orchardBalance: Zatoshi(999_999)) == nil)
    }

    /// MOB-1630: the floor itself is not "below" it — 0.01 ZEC exactly still offers.
    @Test func noRunAtTheOfferFloorOffersTheMigration() {
        #expect(Self.banner(advanceStep: nil, orchardBalance: Zatoshi(1_000_000)) == .required)
    }

    /// The immediate send-max sweep runs without a stored run at all. Its aftermath is deliberately
    /// quiet — the balance is already spent, so there is nothing to prompt.
    @Test func theImmediateSweepIsSilent() {
        #expect(Self.banner(advanceStep: nil, progress: Self.progress(isImmediate: true)) == nil)
    }

    // MARK: - Terminal

    @Test func completeAsksForAnAcknowledgement() {
        #expect(Self.banner(advanceStep: .complete) == .complete)
    }

    @Test func anAcknowledgedCompleteWithNoRemainderIsSilent() {
        #expect(Self.banner(advanceStep: .complete, isCompleteAcknowledged: true) == nil)
    }

    // MARK: - M1: a failed run must never read as complete

    /// Campaign-1 A/B, failed side: the engine reports the `.complete` step for a FAILED run
    /// (upstream's terminal collapse) whose transfers never mined — pre-fix this painted the
    /// green "Migration complete" banner over a run that moved nothing.
    @Test func aTerminalRunWithUnminedTransfersAsksForAttentionNotComplete() {
        let statuses = [
            Self.status(id: 0, kind: .preparation(layer: 0, index: 0), state: .signed),
            Self.status(id: 4, kind: .transfer(crossing: 0), state: .signed)
        ]
        let state = MigrationState.derive(
            advanceStep: .complete,
            progress: nil,
            statuses: statuses,
            hasInvalidTransfers: false
        )
        #expect(state == .requiresAttention(.invalidTransfer))
    }

    /// Campaign-2 A/B, healthy side: every transfer mined stays `.complete`.
    @Test func aTerminalRunWithEveryTransferMinedStaysComplete() {
        let statuses = [
            Self.status(id: 0, kind: .preparation(layer: 0, index: 0), state: .mined(height: 3_000_100)),
            Self.status(id: 4, kind: .transfer(crossing: 0), state: .mined(height: 3_000_200))
        ]
        let state = MigrationState.derive(
            advanceStep: .complete,
            progress: nil,
            statuses: statuses,
            hasInvalidTransfers: false
        )
        #expect(state == .complete)
    }

    /// A finished-and-cleared run (no statuses at all) reads no differently than before.
    @Test func aTerminalRunWithNoStatusesStaysComplete() {
        let state = MigrationState.derive(
            advanceStep: .complete,
            progress: nil,
            statuses: [],
            hasInvalidTransfers: false
        )
        #expect(state == .complete)
    }

    // MARK: - Rebuild

    /// `.rebuild` is the engine saying a transfer expired unmined: its pre-signed artifact is dead
    /// (the signature commits to the expiry height), so this is a user-facing recovery, not a retry.
    @Test func rebuildSurfacesAsExpired() {
        let rows = [
            MigrationTransferRow(id: "1", index: 0, amount: nil, status: .expired, hoursFromNow: 0),
            MigrationTransferRow(id: "2", index: 1, amount: nil, status: .pending, hoursFromNow: 6)
        ]
        #expect(Self.banner(advanceStep: .rebuild(id: 1), transferRows: rows) == .transfersExpired(first: 1, last: 1))
    }

    // MARK: - The engine's own replan step (SDK addendum §2; split vocabulary 2026-08-08)

    /// Upstream surfaces `.replan` when the run's plan was undercut past its committed threshold.
    /// The app honours that verdict rather than re-deriving it — and lands on the same run-level
    /// banner the coverage signal produces, because "your plan needs redoing" is a statement about
    /// the run either way.
    @Test func theEnginesReplanStepSurfacesAsUpdatePlan() {
        #expect(Self.banner(advanceStep: .replan, progress: Self.progress()) == .updatePlan)
    }

    /// It needs no help from the app's own invalidation read — the engine already decided.
    @Test func theReplanStepDoesNotNeedTheAppsOwnInvalidFlag() {
        let withFlag = Self.banner(advanceStep: .replan, hasInvalid: true)
        let withoutFlag = Self.banner(advanceStep: .replan, hasInvalid: false)
        #expect(withFlag == withoutFlag)
    }

    // MARK: - Invalidation outranks the step

    /// The precedence that A28 made reachable. The engine can still report a perfectly live
    /// `.waiting` for a run whose funding notes were spent elsewhere — it has no way to know until
    /// the app's invalidation sweep tells it — so a live-looking step must not mask a dead run.
    @Test(arguments: [MigrationAdvanceStep.waiting, .prove(transactions: [MigrationProveTarget(id: 1, kind: .transfer(crossing: 0))]), .broadcast(MigrationBroadcastInstruction(id: 1))])
    func invalidationOutranksALiveStep(step: MigrationAdvanceStep) {
        #expect(Self.banner(advanceStep: step, hasInvalid: true) == .updatePlan)
    }

    // MARK: - Running

    /// RE-PINNED twice, each on a ruling. The rows are the authority on "is the app doing work
    /// right now" (the 08-02 `isInFlight` narrowing), and this fixture carries NO in-flight rows —
    /// so even under a `.prove` step, nothing is actionable THIS session (the gate-refused window
    /// FIND-1 documented). THE BANNER MAP (Lukas, 2026-08-06) names that render: the AT-OPEN
    /// counts idle (`.idleCounts`), never the notify line (`.idle` is termination-only,
    /// store-entered) and never a numberless progress claim.
    @Test func aProveStepWithoutInFlightRowsReadsAsIdle() {
        let variant = Self.banner(
            advanceStep: .prove(transactions: [MigrationProveTarget(id: 1, kind: .transfer(crossing: 0))]),
            progress: Self.progress()
        )
        #expect(variant == .idleCounts(done: 0, total: 0))
    }

    /// A run whose preparations have not all mined is still SPLITTING — and that reads as progress,
    /// not as "Migration Required" (which is what the retired `.splitting` variant said, and exactly
    /// the post-confirm confusion QA reported).
    ///
    /// MOB-1466 (2026-08-01): the variant moved from `.inProgress` to `.preparing(isWorkingNow:)`.
    /// The INVARIANT this test exists for is untouched and is now asserted directly — the split
    /// phase wears the run-level "Migration Progress" title, never the fresh-offer one. The old
    /// expectation pinned the case rather than the claim, which is why a change that preserved the
    /// claim exactly still broke it.
    @Test func anUnminedPreparationReadsAsProgressNotAsAFreshOffer() {
        let statuses = [
            Self.status(id: 1, kind: .preparation(layer: 0, index: 0), state: .mined(height: 100)),
            Self.status(id: 2, kind: .preparation(layer: 1, index: 0), state: .broadcast(txid: Data()))
        ]
        let rows = [MigrationTransferRow(id: "10", index: 0, amount: nil, status: .pending, hoursFromNow: 6)]
        let variant = Self.banner(
            advanceStep: .prove(transactions: [MigrationProveTarget(id: 2, kind: .preparation(layer: 1, index: 0))]),
            progress: Self.progress(),
            statuses: statuses,
            transferRows: rows
        )
        #expect(variant == MigrationBannerVariant.inProgress(done: 0, total: 1, round: nil, totalRounds: nil))
        #expect(variant?.title == MigrationBannerVariant.inProgress(done: 0, total: 1, round: nil, totalRounds: nil).title)
        #expect(variant?.title != MigrationBannerVariant.required.title, "never a fresh offer mid-split")
    }

    /// THE BANNER MAP (Lukas, 2026-08-06): engine `.waiting` is the AT-OPEN idle — the counts
    /// status readout (`.idleCounts`, Figma 5139:34962), never a CTA. Overdue-ness changes
    /// nothing here: the open auto-serves it, so there is no "waiting" state left to ask with.
    @Test func waitingReadsAsTheAtOpenCounts() {
        let variant = Self.banner(advanceStep: .waiting, progress: Self.progress())
        #expect(variant == .idleCounts(done: 0, total: 0))
    }

    // MARK: - Broadcast

    /// A13: the engine says broadcast, the app is broadcasting, the banner says so.
    @Test func aDrivenBroadcastReadsAsSending() {
        let variant = Self.banner(
            advanceStep: .broadcast(MigrationBroadcastInstruction(id: 1)),
            progress: Self.progress(),
            isBroadcastInFlight: true
        )
        #expect(variant == .transferSending(number: 2))
    }

    // MARK: - Coverage

    /// Every advance step the engine can report produces SOME user-visible answer — none of them
    /// falls into a hole that renders nothing while a run is live.
    @Test(arguments: [
        MigrationAdvanceStep.prove(transactions: [MigrationProveTarget(id: 1, kind: .transfer(crossing: 0))]),
        .prove(transactions: [MigrationProveTarget(id: 1, kind: .preparation(layer: 0, index: 0))]),
        .broadcast(MigrationBroadcastInstruction(id: 1)),
        .rebuild(id: 1),
        .waiting,
        .complete,
        .replan,
        .reevaluate
    ])
    func everyAdvanceStepProducesABanner(step: MigrationAdvanceStep) {
        #expect(Self.banner(advanceStep: step, progress: Self.progress()) != nil)
    }
}
