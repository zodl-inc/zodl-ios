//
//  MigrationBroadcastBannerTests.swift
//  zodlTests
//
//  Covers A13's pure seam: `MigrationDerivations.bannerVariant`'s `isBroadcastInFlight` arm, which
//  raises `.transferSending` while `MigrationManagerImpl.runBroadcastSession` is submitting.
//
//  The precedence is the whole point and is what these pin. During a headless broadcast, other
//  banner arms' inputs can be simultaneously live — whichever arm is checked first wins, so the
//  ordering is load-bearing, not incidental: any competing banner while the transfer is going out
//  over the wire misleads, when the one thing this session actually needs is for the user to keep
//  the app open. THE BANNER MAP (Lukas, 2026-08-06) adds
//  the KIND fork: a note-PREPARATION submit wears keep-open (`.preparing`), never
//  "Transfer N is sending".
//

import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationBroadcastBannerTests {
    // MARK: - Fixtures

    private static func progress(completed: Int, total: Int, isImmediate: Bool = false) -> MigrationProgress {
        MigrationProgress(
            completedTransfers: completed,
            totalTransfers: total,
            remainingOrchard: Zatoshi(500_000_000),
            nextTransferReadyAtHeight: 3_000_000,
            isImmediate: isImmediate
        )
    }

    /// Every input at its quiet default except the ones a test varies — so a failure names the one
    /// signal that moved.
    private static func variant(
        state: MigrationState,
        isBroadcastInFlight: Bool = false,
        isPreparationBroadcastInFlight: Bool = false
    ) -> MigrationBannerVariant? {
        MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: state,
            orchardBalance: Zatoshi(500_000_000),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: [],
            isBroadcastInFlight: isBroadcastInFlight,
            isPreparationBroadcastInFlight: isPreparationBroadcastInFlight
        )
    }

    // MARK: - The sending banner

    /// Numbering matches every other per-transfer arm: the transfer IN FLIGHT is the one after the
    /// last completed one.
    @Test func inFlightBroadcastReadsAsSending() {
        let variant = Self.variant(state: .inProgress(Self.progress(completed: 2, total: 6)), isBroadcastInFlight: true)
        #expect(variant == .transferSending(number: 3))
    }

    /// THE BANNER MAP's kind fork: a note-PREPARATION going out mid-`.inProgress` wears the
    /// keep-open costume — splits have no banner copy of their own, and "Transfer N is sending"
    /// over a split would name a transfer that is not moving.
    @Test func aPreparationBroadcastWearsKeepOpenNotSending() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 3)),
            isBroadcastInFlight: true,
            isPreparationBroadcastInFlight: true
        )
        #expect(variant == .preparing(done: 0, total: 0))
        #expect(variant?.isPreparingVariant == true)
    }

    /// A manual-delivery run reaches a broadcast only because the user tapped Send. Once it is in
    /// flight, re-offering "Review" would invite a second tap on a transfer already going out.
    @Test func sendingBeatsReadyInAManualRun() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 1, total: 4)),
            isBroadcastInFlight: true
        )
        #expect(variant == .transferSending(number: 2))
    }

    /// The immediate (send-max) lane keeps its deliberate silence — it broadcasts from its own
    /// full-screen Sending flow, so there is no banner to raise behind it. The `isImmediate` guard
    /// stays AHEAD of the in-flight check for that reason.
    @Test func theImmediateLaneStaysQuietEvenMidBroadcast() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 1, isImmediate: true)),
            isBroadcastInFlight: true
        )
        #expect(variant == nil)
    }

    // MARK: - No regression when nothing is in flight

    /// THE BANNER MAP (2026-08-06): with `.transferWaiting` removed, nothing-in-flight reads as
    /// the at-open counts idle — overdue or not, the open auto-serves.
    @Test func nothingInFlightReadsAsTheAtOpenCounts() {
        let variant = Self.variant(state: .inProgress(Self.progress(completed: 2, total: 6)))
        #expect(variant == .idleCounts(done: 0, total: 0))
    }

    /// The parameter defaults to `false`, so every pre-A13 call site — none of which know the flag
    /// exists — derives exactly what it derived before.
    @Test func omittingTheFlagMatchesPassingItFalse() {
        let omitted = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: .inProgress(Self.progress(completed: 2, total: 6)),
            orchardBalance: Zatoshi(500_000_000),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: []
        )
        #expect(omitted == Self.variant(state: .inProgress(Self.progress(completed: 2, total: 6))))
    }

    // MARK: - The flag is scoped to a run in progress

    /// A run that is not in progress cannot have a transfer in flight, and the flag must not be
    /// able to manufacture a sending banner out of a terminal or unstarted state.
    @Test(arguments: [MigrationState.notStarted, .complete, .requiresAttention(.transferExpired)])
    func theFlagDoesNotLeakOutsideAnInProgressRun(state: MigrationState) {
        #expect(Self.variant(state: state, isBroadcastInFlight: true) == Self.variant(state: state))
    }
}
