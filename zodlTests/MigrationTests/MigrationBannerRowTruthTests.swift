//
//  MigrationBannerRowTruthTests.swift
//  zodlTests
//
//  MOB-1466, the smart-banner pass: the banner and the transfer timeline must tell the same story,
//  because they are two views of one run and the user sees them within one tap of each other.
//
//  They did not. The banner derived "which transfer" from `MigrationProgress.completedTransfers`,
//  which counts MINED transfers, while the timeline numbered rows by position. A transfer mines
//  minutes after it sends, so for that entire window the banner named the transfer that had already
//  gone out and the timeline named the next one. Field report, verbatim: "transfer 1 has been done,
//  transfer 2 ready but smart widget still writes transfer 1".
//
//  What these pin is the replacement rule — the banner reads the same live ROWS the timeline
//  renders — and the line that rule had to learn the hard way:
//
//  - The NUMBERS come from row position in both surfaces, so they agree by construction.
//  - PREPARING exists, a state the banner had no word for at all, during the longest phase of a run.
//  - A KEEP-OPEN ASK belongs only to work that dies when the app closes. The first cut raised it
//    from the durable `.broadcast(txid:)` row, which means SUBMITTED and awaiting mining — minutes
//    during which the SDK's own post-broadcast buffer holds sync so the wallet cannot even observe
//    the mining. The banner asked the user to watch a spinner while the app did nothing, and the
//    tester read three minutes of it as a hang. The row still names WHICH transfer; the in-session
//    `isBroadcastInFlight` flag decides whether we may ask them to stay.
//
//  On iOS this is not decoration. Zodl has no background lane: proving and broadcasting happen only
//  while the app is open and on screen. A banner that says nothing — or says "waiting" — during work
//  that only runs on screen is what makes the user close the app and stop it. The mirror failure is
//  just as bad: asking them to stay for work that is already out of our hands teaches them the ask
//  means nothing.
//

import Foundation
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationBannerRowTruthTests {
    // MARK: - Fixtures

    private static let clock = MigrationChainClock(tip: 3_000_000)

    private static func progress(completed: Int, total: Int, isImmediate: Bool = false) -> MigrationProgress {
        MigrationProgress(
            completedTransfers: completed,
            totalTransfers: total,
            remainingOrchard: Zatoshi(500_000_000),
            nextTransferReadyAtHeight: 3_000_000,
            isImmediate: isImmediate
        )
    }

    private static func row(
        index: Int,
        status: MigrationTransferRow.Status,
        isBroadcasting: Bool = false,
        isPreparing: Bool = false,
        kind: MigrationTransferRow.Kind = .transfer
    ) -> MigrationTransferRow {
        MigrationTransferRow(
            id: "\(index)",
            index: index,
            amount: Zatoshi(100_000_000),
            status: status,
            hoursFromNow: 0,
            isBroadcasting: isBroadcasting,
            isPreparing: isPreparing,
            kind: kind
        )
    }

    private static func variant(
        state: MigrationState,
        transferRows: [MigrationTransferRow],
        preparationRows: [MigrationTransferRow] = [],
        isBroadcastInFlight: Bool = false,
        activeBroadcastTxId: UInt32? = nil,
        progressCompleted: Int = 0,
        progressTotal: Int = 6
    ) -> MigrationBannerVariant? {
        MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: state,
            orchardBalance: Zatoshi(500_000_000),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: transferRows,
            preparationRows: preparationRows,
            isBroadcastInFlight: isBroadcastInFlight,
            activeBroadcastTxId: activeBroadcastTxId
        )
    }

    private static func status(
        id: UInt32,
        kind: MigrationTransactionStatus.Kind,
        state: MigrationTransactionStatus.State,
        isReady: Bool = false,
        nextAction: MigrationTransactionStatus.NextAction? = nil,
        blockedOn: MigrationTransactionStatus.Blocker? = nil
    ) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: kind,
            state: state,
            scheduledHeight: 3_000_100,
            expiryHeight: nil,
            isReady: isReady,
            nextAction: nextAction,
            blockedOn: blockedOn,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    // MARK: - Sending, from durable row state

    /// THE correction, field-caught 2026-08-01. A `.broadcast(txid:)` row means SUBMITTED and
    /// awaiting mining — minutes, during which the SDK's post-broadcast buffer holds sync so the
    /// wallet cannot even observe the mining. Raising the keep-open banner off it asked the user to
    /// sit and watch a spinner while the app did nothing, and the tester read that as a hang.
    ///
    /// Leaving costs the user nothing once the transaction is on the wire. Only work that dies when
    /// the app closes may ask them to stay.
    @Test func aBroadcastRowAloneDoesNotAskTheUserToStay() {
        // R11 re-pin: a broadcast row's status is `.confirming` now (never `.active`), and the
        // fixture carries the run's FULL row set — the banner counts the rows the screen renders
        // (R5), so a 6-transfer run is six rows, not two rows plus a progress claim of six.
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .confirming, isBroadcasting: true),
                Self.row(index: 1, status: .pending),
                Self.row(index: 2, status: .pending),
                Self.row(index: 3, status: .pending),
                Self.row(index: 4, status: .pending),
                Self.row(index: 5, status: .pending)
            ]
        )
        #expect(variant != .transferSending(number: 1))
        // THE BANNER MAP (2026-08-06): a confirming broadcast leaves nothing actionable this
        // session — the wire has the transaction, mining is the chain's job — so the run reads
        // as the at-open counts idle (idle2). The notify idle is termination-only, store-entered.
        #expect(variant == .idleCounts(done: 0, total: 6))
    }

    /// Same rule in the split phase, where it actually bit: a broadcast Split Balance awaiting its
    /// mining is not a reason to keep the app open.
    @Test func aBroadcastPreparationAloneDoesNotAskTheUserToStay() {
        let variant = Self.variant(
            state: .splitPendingConfirmation,
            transferRows: [Self.row(index: 0, status: .pending)],
            preparationRows: [Self.row(index: 0, status: .active, isBroadcasting: true, kind: .splitBalance)]
        )
        #expect(variant?.isPreparingVariant != true)
    }

    /// The submission itself DOES ask — that window is seconds long and dies with the app.
    @Test func anInFlightSubmissionAsksTheUserToStay() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [Self.row(index: 0, status: .active)],
            isBroadcastInFlight: true
        )
        #expect(variant == .transferSending(number: 1))
    }

    /// GROUND_RULES D6: the NUMBER is the id the session is ACTUALLY submitting, carried from the
    /// manager's own record — never inferred from `isBroadcasting` rows. The old inference named
    /// the PREVIOUS transfer whenever one was still broadcast-but-unmined while a new one went out
    /// (field: "T8 is sending..." during T9's submit). Here the active id names row index 1 and the
    /// banner says Transfer 2 — where the mined count would have said 1, and the old row inference
    /// would have too if an earlier unmined broadcast were present.
    @Test func theSendingNumberIsTheSessionsOwnId() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .active, isBroadcasting: true)
            ],
            isBroadcastInFlight: true,
            activeBroadcastTxId: 1
        )
        #expect(variant == .transferSending(number: 2), "the mined count would have said Transfer 1")
    }

    /// THE FIELD CASE, pinned: T8 broadcast-but-unmined from the previous window, T9 submitting
    /// NOW. Two rows on the wire; the banner names the session's own (T9), not the older one the
    /// row inference used to pick.
    @Test func aPreviousUnminedBroadcastDoesNotStealTheSendingNumber() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 7, total: 12)),
            transferRows: [
                Self.row(index: 7, status: .active, isBroadcasting: true),
                Self.row(index: 8, status: .active, isBroadcasting: true)
            ],
            isBroadcastInFlight: true,
            activeBroadcastTxId: 8
        )
        #expect(variant == .transferSending(number: 9), "must name T9 (the session's id), not the unmined T8")
    }

    /// THE BANNER MAP (2026-08-06): an overdue row no longer raises a waiting banner — overdue is
    /// iOS reality awaiting the next open/tick, and the open auto-serves. Until that serve fires,
    /// the honest render is the at-open counts (rows-truth done count, not the lagging mined
    /// count).
    @Test func anOverdueRowReadsAsTheAtOpenCountsAwaitingItsAutoServe() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .overdue)
            ]
        )
        #expect(variant == .idleCounts(done: 1, total: 2))
    }

    // (`withoutRowsTheMinedCountStillDrivesTheNumber` retired with `.transferWaiting` — THE
    // BANNER MAP, 2026-08-06. The mined-count fallback for per-transfer numbering survives in the
    // sending arm and is pinned by the sending tests above.)

    // MARK: - Preparing

    /// The state the banner had no word for. A transfer the engine says it can prove right now is
    /// work happening in this session — and on iOS, work that stops when the app closes.
    @Test func aProvableRowRaisesPreparing() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [Self.row(index: 0, status: .active, isPreparing: true)]
        )
        #expect(variant?.isPreparingVariant == true)
    }

    /// A transfer whose window passed while its proof is outstanding is un-sendable but genuinely
    /// being worked — the keep-open ask is the true state, not a status readout.
    @Test func anOverdueUnprovedRowStillReadsAsPreparing() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [Self.row(index: 0, status: .overdue, isPreparing: true)]
        )
        #expect(variant?.isPreparingVariant == true)
    }

    /// Same reason in the manual lane: offering Review for a transfer that cannot be sent yet ends
    /// in the same dead end, one screen deeper.
    @Test func preparingBeatsReady() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [Self.row(index: 0, status: .active, isPreparing: true)]
        )
        #expect(variant?.isPreparingVariant == true)
    }

    /// But a broadcast already in flight outranks it — that transfer is past preparing, and naming
    /// the delivery is the more specific truth. D6: the number comes from the session's active id.
    @Test func sendingBeatsPreparing() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .active, isBroadcasting: true),
                Self.row(index: 1, status: .pending, isPreparing: true)
            ],
            isBroadcastInFlight: true,
            activeBroadcastTxId: 0
        )
        #expect(variant == .transferSending(number: 1))
    }

    /// Preparing is RUN-level and plural: one prove sweep proves the whole run, and Figma C5 shows
    /// two transfers preparing at once. Any BLOCKED provable row raises it, wherever it sits — the
    /// second row here, not the first.
    @Test func preparingIsRaisedByAnyRowNotJustTheFirst() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .active),
                Self.row(index: 1, status: .overdue, isPreparing: true)
            ]
        )
        #expect(variant?.isPreparingVariant == true)
    }

    /// …but a PENDING row that merely happens to be provable does NOT raise it, and this is the
    /// half the field had to teach us (2026-08-02, session s2).
    ///
    /// `isPreparing` means "the engine COULD prove this one". Provability is gated on each
    /// transfer's own anchor boundary, drawn on a jittered grid, so it fires for rows whose send
    /// window is still ten minutes out. Four such rows flipped a whole run's banner to "preparing":
    ///
    ///     BANNER: (first) → preparing · why: the prove sweep will run this session
    ///     ROWS:   … T7:preparing T8:preparing T9:preparing T10:preparing T11:~11m
    ///     ══ BACKGROUND — prove sweeps 0 · syncs completed 0
    ///
    /// The sweep did not run and could not: `start()` had been refused by the privacy gate, so
    /// there was no sync, no sync-complete edge, and no `advance(.afterSync)`. Forty-eight seconds
    /// of a banner promising imminent work over a session that did nothing.
    ///
    /// A run is only "preparing" when a row the user is actually waiting on cannot move for want of
    /// its proof. Everything else is progress.
    @Test func aPendingRowThatIsMerelyProvableDoesNotClaimTheRunIsPreparing() {
        // R11 re-pin: full 6-row fixture — banner counts the rows themselves (R5).
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .active),
                Self.row(index: 1, status: .pending, isPreparing: true),
                Self.row(index: 2, status: .pending, isPreparing: true),
                Self.row(index: 3, status: .pending),
                Self.row(index: 4, status: .pending),
                Self.row(index: 5, status: .pending)
            ]
        )

        #expect(variant?.isPreparingVariant != true)
        // THE BANNER MAP (2026-08-06): dep-vetoed provable rows are "nothing actionable this
        // session" — the at-open counts idle, FIND-1's no-false-promise rule in its current form.
        #expect(variant == .idleCounts(done: 0, total: 6))
    }

    /// A note-split preparation is work exactly as much as a crossing transfer is, and the split
    /// phase is where a large wallet spends its first minutes with the app open.
    @Test func aProvablePreparationRaisesPreparingDuringTheSplitPhase() {
        let variant = Self.variant(
            state: .splitPendingConfirmation,
            transferRows: [Self.row(index: 0, status: .pending)],
            preparationRows: [Self.row(index: 0, status: .active, isPreparing: true, kind: .splitBalance)]
        )
        #expect(variant?.isPreparingVariant == true)
    }

    /// FIELD-CAUGHT 2026-08-01. A note-split is proved at commit and BROADCAST later, in its own
    /// scheduled window — ZIP 318 applies to preparations too — so the split's broadcast happens
    /// inside `splitPendingConfirmation`, not `.inProgress`. The first cut of this pass added the
    /// preparing check to that arm and left the broadcast check in `.inProgress` only, so the
    /// banner read "We'll notify you when to send" while the timeline one tap away read
    /// "Split Balance 1 · Sending now". Same disagreement, one arm later.
    @Test func aPreparationBeingSubmittedRaisesPreparingNotIdle() {
        let variant = Self.variant(
            state: .splitPendingConfirmation,
            transferRows: [Self.row(index: 0, status: .pending)],
            preparationRows: [Self.row(index: 0, status: .active, isBroadcasting: true, kind: .splitBalance)],
            isBroadcastInFlight: true
        )
        #expect(variant?.isPreparingVariant == true)
    }

    /// `.preparing` and not `.transferSending`, deliberately: the thing going out is a Split
    /// Balance, not a numbered transfer, and "Transfer 1 is sending…" over a split would be a
    /// confident lie.
    @Test func aPreparationBeingSubmittedIsNeverNumberedAsATransfer() {
        let variant = Self.variant(
            state: .splitPendingConfirmation,
            transferRows: [Self.row(index: 0, status: .pending)],
            preparationRows: [Self.row(index: 0, status: .active, isBroadcasting: true, kind: .splitBalance)],
            isBroadcastInFlight: true
        )
        #expect(variant != .transferSending(number: 1))
    }

    /// The in-session flag has to be read in this arm too. It is set the instant
    /// `runBroadcastSession` starts and pokes — which is exactly the moment the field log caught,
    /// seconds before the engine had written `.broadcast` to any row.
    @Test func theInFlightFlagAloneRaisesPreparingDuringTheSplitPhase() {
        let variant = Self.variant(
            state: .splitPendingConfirmation,
            transferRows: [Self.row(index: 0, status: .pending)],
            isBroadcastInFlight: true
        )
        #expect(variant?.isPreparingVariant == true)
    }

    /// The immediate (send-max) lane keeps its deliberate silence — it runs behind its own
    /// full-screen Sending flow, so there is no banner to raise. The `isImmediate` guard stays
    /// ahead of every new arm.
    @Test func theImmediateLaneStaysQuietWhilePreparing() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 0, total: 1, isImmediate: true)),
            transferRows: [Self.row(index: 0, status: .active, isPreparing: true)]
        )
        #expect(variant == nil)
    }

    // MARK: - Idle

    /// THE PIN THAT HAS NOW FLIPPED THREE TIMES, each on a product ruling — carry the whole
    /// history. (1) First wiring rendered "We'll notify you when to send" as the universal idle
    /// line; (2) the full-canvas walk reversed it to counts and left the notify line orphaned
    /// pending a trigger rule; (3) flow ID ratified `.waiting ⇒ notify` for every idle entry;
    /// (4) THE BANNER MAP (Lukas, 2026-08-06) split the idles by ENTRY PATH: the derivation's
    /// nothing-actionable answer is the AT-OPEN counts idle (`.idleCounts`, Figma 5139:34962),
    /// and the notify line (`.idle`, 35439) is TERMINATION-only — store-entered when a pending
    /// state finishes (see `SmartBanner.resolvingIdleTermination` and its test). Do not flip this
    /// again without a new map.
    @Test func anIdleRunReadsAsTheAtOpenCounts() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 1, total: 6)),
            transferRows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .pending),
                Self.row(index: 2, status: .pending),
                Self.row(index: 3, status: .pending),
                Self.row(index: 4, status: .pending),
                Self.row(index: 5, status: .pending)
            ]
        )
        #expect(variant == .idleCounts(done: 1, total: 6))
        #expect(variant?.info == MigrationBannerVariant.inProgress(done: 1, total: 6, round: nil, totalRounds: nil).info)
    }

    /// Both work-in-flight states carry the same second line — WHILE the run has no numbers to
    /// show yet. Figma 5139:35270 and 5139:34287 print it identically.
    @Test func bothWorkingStatesAskTheUserToStay() {
        let keepOpen = "Keep Zodl open on active phone screen"
        #expect(MigrationBannerVariant.preparing(done: 0, total: 6).info == keepOpen)
        #expect(MigrationBannerVariant.transferSending(number: 1).info == keepOpen)
    }

    /// FIND-6 (2026-08-05, campaign 7): MONOTONE INFORMATION. Once the banner has shown real
    /// progress ("1 of 11 · 9%"), flipping to `.preparing` must NOT replace the numbers with a
    /// numberless spinner — the field watched exactly that for 12 minutes and read it as the run
    /// breaking. With `done > 0` the preparing banner renders the SAME designed counts line
    /// `.inProgress` shows; the spinner icon alone says work is running.
    @Test func preparingKeepsTheCountsOnceProgressExists() {
        #expect(
            MigrationBannerVariant.preparing(done: 1, total: 11).info
                == MigrationBannerVariant.inProgress(done: 1, total: 11, round: nil, totalRounds: nil).info,
            "numbers, once shown, are never taken back by the preparing costume"
        )
    }

    /// Preparing is run-level, so it borrows the run-level title and the run-level button — it is
    /// not about one transfer and must not offer to review one.
    @Test func preparingIsTitledAndButtonedAtRunLevel() {
        #expect(
            MigrationBannerVariant.preparing(done: 0, total: 6).title
                == MigrationBannerVariant.inProgress(done: 0, total: 6, round: nil, totalRounds: nil).title
        )
        #expect(MigrationBannerVariant.preparing(done: 0, total: 6).buttonLabel == MigrationBannerVariant.required.buttonLabel)
    }

    // MARK: - The row flag itself

    /// `isPreparing` is the ENGINE's readiness verdict, not a lifecycle guess. `isReady` +
    /// `nextAction == .prove` is the engine saying, in as many words, "you can prove this now".
    @Test func aReadyToProveStatusMarksTheRowPreparing() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), state: .signed, isReady: true, nextAction: .prove)],
            clock: Self.clock
        )
        #expect(rows?[0].isPreparing == true)
    }

    /// And the case that makes readiness the right signal rather than the `.signed` state: a
    /// transfer whose anchor boundary the wallet has not scanned yet is `.signed` too, and nothing
    /// the user does by staying makes it prove. That row must NOT wear a "keep Zodl open" ask.
    ///
    /// This is the shape of the bug that blocked the first successful transfer for a full day —
    /// signed, unprovable, retried forever. Keeping it out of `.preparing` is what stops the banner
    /// from asking the user to sit and watch a stall.
    @Test func aSignedButAnchorBlockedStatusIsNotPreparing() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), state: .signed, blockedOn: .anchorBoundary)],
            clock: Self.clock
        )
        #expect(rows?[0].isPreparing == false)
    }

    /// A proved transfer waiting for its window is ready to BROADCAST, not to prove — nothing is
    /// running, and the idle banner is the honest one.
    @Test func aProvedRowAwaitingItsWindowIsNotPreparing() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), state: .proved, isReady: true, nextAction: .broadcast)],
            clock: Self.clock
        )
        #expect(rows?[0].isPreparing == false)
    }

    /// A mined transfer is finished; readiness is meaningless on it and the flag must stay off, or
    /// a completed row would carry a spinner.
    @Test func aMinedRowIsNeverPreparing() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), state: .mined(height: 2_999_000), isReady: true, nextAction: .prove)],
            clock: Self.clock
        )
        #expect(rows?[0].isPreparing == false)
        #expect(rows?[0].status == .sent)
    }

    /// `isInFlight` is what the timeline's spinner reads, and it is PROVING ONLY.
    ///
    /// `isBroadcasting` was dropped from it 2026-08-01, with the caption, for one reason: a
    /// `.broadcast(txid:)` row is submitted and awaiting mining — minutes — and a spinner over it
    /// claims the app is working when the remaining work is the chain's. Field report that produced
    /// this: "there is never ending sending of split 1." A spinner that never stops is how a wallet
    /// teaches someone it is broken.
    @Test func inFlightIsProvingOnly() {
        #expect(Self.row(index: 0, status: .active, isPreparing: true).isInFlight)
        #expect(
            !Self.row(index: 0, status: .active, isBroadcasting: true).isInFlight,
            "a broadcast row is waiting on the chain, not on us"
        )
        #expect(!Self.row(index: 0, status: .active).isInFlight)
        #expect(!Self.row(index: 0, status: .sent).isInFlight)
    }

    // MARK: - No regressions on the quiet paths

    /// A terminal or unstarted run cannot have work in flight, and the two new row FLAGS must not
    /// be able to manufacture a preparing or sending banner out of one. Compared against the same
    /// rows with the flags cleared, so the comparison isolates the flags — `.transfersExpired` does
    /// legitimately read the rows (for its first/last bounds), and always has.
    @Test(arguments: [MigrationState.notStarted, .complete, .requiresAttention(.transferExpired)])
    func theNewRowFlagsDoNotLeakOutsideAnInProgressRun(state: MigrationState) {
        let flagged = Self.variant(
            state: state,
            transferRows: [
                Self.row(index: 0, status: .expired, isBroadcasting: true, isPreparing: true)
            ]
        )
        let unflagged = Self.variant(
            state: state,
            transferRows: [Self.row(index: 0, status: .expired)]
        )
        #expect(flagged == unflagged)
        #expect(flagged?.isPreparingVariant != true)
    }

    /// The defaulted parameters default, so a call site that knows none of them derives the
    /// quiet answer.
    @Test func omittingTheNewParametersMatchesTheOldSignature() {
        let omitted = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: .inProgress(Self.progress(completed: 2, total: 6)),
            orchardBalance: Zatoshi(500_000_000),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: []
        )
        #expect(omitted == .idleCounts(done: 0, total: 0))
    }
}

// MARK: - The stall verdict

/// MOB-1466, field-caught 2026-08-02 on an overnight run.
///
/// Twelve transfers all reported `blocked -` — nil, i.e. the engine saying "actionable now" — with
/// anchors ~800 blocks BEHIND the scanned tip, and every prove sweep produced zero. The app showed
/// twelve "Preparing transaction…" spinners and a "Keep Zodl open on active phone screen" banner,
/// and the tester sat there for minutes because that is what it asked for.
///
/// The rule these pin: THE APP MAY ONLY ASK THE USER TO STAY FOR WORK THAT IS ACTUALLY HAPPENING.
/// The engine's readiness verdict is necessary but not sufficient — once sweeps have demonstrably
/// produced nothing against that verdict, the claim is revoked, because a spinner over stopped work
/// spends the credibility every future keep-open ask depends on.
@Suite struct MigrationProveStallTests {
    private static let clock = MigrationChainClock(tip: 3_000_000)

    private static func provable(id: UInt32, crossing: Int) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: .transfer(crossing: crossing),
            state: .signed,
            scheduledHeight: 2_999_000,
            expiryHeight: nil,
            isReady: true,
            nextAction: .prove,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: 2_998_000
        )
    }

    /// The engine's verdict alone still drives the caption while proving is working.
    @Test func aProvableRowPreparesWhileProvingWorks() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.provable(id: 1, crossing: 0)],
            clock: Self.clock,
            isProvingStalled: false
        )
        #expect(rows?[0].isPreparing == true)
        #expect(rows?[0].isInFlight == true, "the spinner is on")
    }

    /// And is revoked once the app has watched proving produce nothing. Same engine answer, same
    /// row — different claim, because the claim was about US, not about the engine.
    @Test func aStalledSweepRevokesTheClaim() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.provable(id: 1, crossing: 0)],
            clock: Self.clock,
            isProvingStalled: true
        )
        #expect(rows?[0].isPreparing == false)
        #expect(rows?[0].isInFlight == false, "no spinner over work that is not happening")
    }

    /// Which is what drops the banner's keep-open ask: `.preparing` derives from the rows, so
    /// revoking the row flag revokes the ask with it — no separate gate to keep in step.
    @Test func aStalledSweepDropsTheKeepOpenBanner() {
        let stalledRows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.provable(id: 1, crossing: 0)],
            clock: Self.clock,
            isProvingStalled: true
        ) ?? []

        let variant = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: .inProgress(
                MigrationProgress(
                    completedTransfers: 0,
                    totalTransfers: 12,
                    remainingOrchard: Zatoshi(9_999_760_000),
                    nextTransferReadyAtHeight: 2_999_000,
                    isImmediate: false
                )
            ),
            orchardBalance: Zatoshi(9_999_760_000),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: stalledRows
        )

        #expect(variant?.isPreparingVariant != true, "never ask the user to stay for a sweep that produces nothing")
        // THE BANNER MAP (2026-08-06): with `.transferWaiting` removed, a stalled overdue run
        // reads as the at-open counts — no dead CTA, no keep-open ask. Counts come from the ROWS
        // (one status-derived row here), never the progress claim of twelve — R11's identity.
        #expect(variant == .idleCounts(done: 0, total: 1))
    }

    /// The preparation rows take the same verdict — the split phase is where the first overnight
    /// stall was seen, and its banner asks for the same thing.
    @Test func preparationRowsTakeTheSameVerdict() {
        let statuses = [
            MigrationTransactionStatus(
                id: 0,
                kind: .preparation(layer: 0, index: 0),
                state: .signed,
                scheduledHeight: 2_999_000,
                expiryHeight: nil,
                isReady: true,
                nextAction: .prove,
                blockedOn: nil,
                dependsOn: [],
                anchorBoundaryHeight: nil
            )
        ]
        #expect(MigrationDerivations.preparationRows(statuses: statuses, clock: Self.clock, isProvingStalled: false)?[0].isPreparing == true)
        #expect(MigrationDerivations.preparationRows(statuses: statuses, clock: Self.clock, isProvingStalled: true)?[0].isPreparing == false)
    }

    /// THE SPINNER INVARIANT (Lukas, 2026-08-06): the Prepare Balance sheet takes the same
    /// verdict — it was the one surface still spinning over a stalled sweep (a due step's badge
    /// spinner keyed on schedule alone). Stalled, a due step reads as a quiet `.scheduled` with
    /// no forward time.
    @Test func aStalledSweepQuietsThePrepareSheet() {
        let statuses = [
            MigrationTransactionStatus(
                id: 0,
                kind: .preparation(layer: 0, index: 0),
                state: .signed,
                scheduledHeight: 2_999_000,
                expiryHeight: nil,
                isReady: true,
                nextAction: .prove,
                blockedOn: nil,
                dependsOn: [],
                anchorBoundaryHeight: nil
            )
        ]
        let working = MigrationDerivations.prepareBalanceRows(statuses: statuses, clock: Self.clock, isProvingStalled: false)
        let stalled = MigrationDerivations.prepareBalanceRows(statuses: statuses, clock: Self.clock, isProvingStalled: true)

        #expect(working?[0].state == .preparing)
        #expect(stalled?[0].state == .scheduled, "no badge spinner over a sweep that produces nothing")
        #expect(stalled?[0].minutesFromNow == nil, "a stalled due step promises no time")
    }
}

// MARK: - THE SPINNER INVARIANT (Lukas, 2026-08-06)

/// *"Each banner that has ONGOING = PENDING state means there is really some work in progress —
/// must be visible with a spinner. Terminated, idle, static banners have zero spinners anywhere;
/// ongoing banners must have spinners somewhere."* — the cross-surface rule, executable.
///
/// All the spinner-bearing surfaces derive from the SAME statuses + clock + stall verdict: the
/// banner (`bannerVariant`'s preparing/sending arms), the timeline rows (`isInFlight` drives the
/// row spinner), and the Prepare Balance sheet (`.preparing` drives the badge spinner). Whatever
/// the engine reports, they may only ever tell one story.
@Suite struct MigrationSpinnerInvariantTests {
    private static let clock = MigrationChainClock(tip: 3_000_000, secondsPerBlock: 75)

    private static func status(
        id: UInt32,
        kind: MigrationTransactionStatus.Kind,
        state: MigrationTransactionStatus.State = .signed,
        scheduledHeight: BlockHeight = 2_999_000,
        isReady: Bool = true,
        nextAction: MigrationTransactionStatus.NextAction? = .prove
    ) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: kind,
            state: state,
            scheduledHeight: scheduledHeight,
            expiryHeight: nil,
            isReady: isReady,
            nextAction: nextAction,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    private static func progress(total: Int) -> MigrationProgress {
        MigrationProgress(
            completedTransfers: 0,
            totalTransfers: total,
            remainingOrchard: Zatoshi(500_000_000),
            nextTransferReadyAtHeight: 3_000_100,
            isImmediate: false
        )
    }

    /// The matrix: engine status combinations × the stall verdict. For every cell, the banner's
    /// keep-open claim, the timeline's row spinners and the sheet's badge spinners must agree on
    /// the one question "is app work running?" — a banner asking the user to stay over a
    /// spinner-less list, or a spinner over a quiet banner, are both the contradiction this rule
    /// bans.
    @Test func theSurfacesAgreeOnWhetherWorkIsRunning() {
        let combos: [(name: String, statuses: [MigrationTransactionStatus])] = [
            ("provable transfer, due", [Self.status(id: 1, kind: .transfer(crossing: 0))]),
            ("provable preparation, due", [Self.status(id: 1, kind: .preparation(layer: 0, index: 0))]),
            ("future-scheduled transfer", [Self.status(id: 1, kind: .transfer(crossing: 0), scheduledHeight: 3_100_000, isReady: false, nextAction: nil)]),
            ("broadcast preparation", [Self.status(id: 1, kind: .preparation(layer: 0, index: 0), state: .broadcast(txid: Data()), nextAction: nil)]),
            (
                "mixed: due prep + future transfer",
                [
                    Self.status(id: 1, kind: .preparation(layer: 0, index: 0)),
                    Self.status(id: 2, kind: .transfer(crossing: 0), scheduledHeight: 3_100_000, isReady: false, nextAction: nil)
                ]
            )
        ]

        for stalled in [false, true] {
            for combo in combos {
                let transfers = MigrationDerivations.statusOnlyTransferRows(
                    statuses: combo.statuses,
                    clock: Self.clock,
                    isProvingStalled: stalled
                ) ?? []
                let preparations = MigrationDerivations.preparationRows(
                    statuses: combo.statuses,
                    clock: Self.clock,
                    isProvingStalled: stalled
                ) ?? []
                let sheet = MigrationDerivations.prepareBalanceRows(
                    statuses: combo.statuses,
                    clock: Self.clock,
                    isProvingStalled: stalled
                ) ?? []
                let banner = MigrationDerivations.bannerVariant(
                    isIronwoodActivated: true,
                    state: .inProgress(Self.progress(total: combo.statuses.count)),
                    orchardBalance: Zatoshi(500_000_000),
                    isCompleteAcknowledged: false,
                    isMigrationRemainderPending: false,
                    transferRows: transfers,
                    preparationRows: preparations
                )

                let rowSpinners = (transfers + preparations).contains { $0.isInFlight }
                let sheetSpinners = sheet.contains { if case .preparing = $0.state { return true } else { return false } }
                let bannerOngoing = banner?.isPreparingVariant == true
                let context = "combo=\(combo.name) stalled=\(stalled)"

                #expect(bannerOngoing == rowSpinners, "banner keep-open and row spinners disagree: \(context)")
                if sheetSpinners {
                    #expect(bannerOngoing, "sheet badge spins under a quiet banner: \(context)")
                }
                if stalled {
                    #expect(!bannerOngoing && !rowSpinners && !sheetSpinners, "a stalled sweep must quiet every surface: \(context)")
                }
            }
        }
    }

    /// The sending direction: the submit-window flag raises the banner's keep-open ask, and the
    /// stamped row (`isSubmitting`, keyed to the D6 id by `stampingActiveSubmit`) is what spins
    /// the timeline for exactly that window — `isInFlight` is true for a submitting row
    /// regardless of its schedule state.
    @Test func aLiveSubmitSpinsTheBannerAndTheStampedRow() {
        guard var row = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), isReady: true, nextAction: nil)],
            clock: Self.clock,
            isProvingStalled: false
        )?.first else {
            Issue.record("expected one derived row")
            return
        }
        #expect(!row.isSubmitting)
        row.isSubmitting = true
        #expect(row.isInFlight, "the stamped row spins for the submit window")

        let banner = MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: .inProgress(Self.progress(total: 1)),
            orchardBalance: Zatoshi(500_000_000),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: [row],
            isBroadcastInFlight: true,
            activeBroadcastTxId: 1
        )
        #expect(banner == .transferSending(number: 1), "the flag window is the sending banner")
    }
}
