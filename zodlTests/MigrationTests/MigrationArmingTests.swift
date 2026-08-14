//
//  MigrationArmingTests.swift
//  zodlTests
//
//  MOB-1466 (N1), field-caught 2026-08-01 on a from-scratch restore: the notification arming
//  derived its send date from `migrationTransfers` alone, which filters to `.transfer`-kind
//  statuses. A note-split PREPARATION's broadcast window contributed nothing. With the run in
//  `splitPendingConfirmation` the arm predicted the first TRANSFER's window — an event that cannot
//  happen until the preparations mine — while preparation 0's window was already open and unpoked.
//  The run moved only because the tester opened the app manually.
//
//  These pin the pure halves: the row selection the arm feeds on, and the engine outlook's arming
//  candidate. The lanes that consume them are integration-shaped and covered by the field sheet.
//
//  2026-08-07: this file also held N2, the persisted cross-session sync->send privacy buffer
//  (`MigrationGateStorage.sendGate(now:buffer:)` and its `migrationLastSyncCompletedAt` stamp),
//  plus the buffer clamp on the outlook candidate. All of it is deleted with the buffer itself — a
//  fixed delay between a sync and a send is an identifiable pattern rather than a defense against
//  one, the same ruling that removed the SDK's post-broadcast buffer. Nothing replaced it, so
//  there is nothing left here to pin: the tests went with the behavior.
//
import Foundation
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationArmingTests {
    // MARK: - Fixtures

    private static let clock = MigrationChainClock(tip: 3_000_000)

    private static func status(
        id: UInt32,
        kind: MigrationTransactionStatus.Kind,
        state: MigrationTransactionStatus.State,
        scheduledHeight: BlockHeight,
        isReady: Bool = false,
        nextAction: MigrationTransactionStatus.NextAction? = nil
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

    /// The arm's own selection rule, extracted verbatim: the earliest row across BOTH lists that
    /// still needs a broadcast.
    private static func nextBroadcast(
        preparations: [MigrationTransferRow],
        transfers: [MigrationTransferRow]
    ) -> MigrationTransferRow? {
        (preparations + transfers)
            .filter { $0.status != MigrationTransferRow.Status.sent && !$0.isBroadcasting }
            // MOB-1466: mirrors the production ordering — a row with no ETA (unknown tip) sorts
            // LAST, so it can never be picked as the soonest.
            .min { ($0.forwardETAMinutes ?? Int.max) < ($1.forwardETAMinutes ?? Int.max) }
    }

    // MARK: - N1: the arm sees the whole run

    /// THE field case. The run is in the split phase: preparation 0's window is open now, the first
    /// transfer's is nearly an hour out and cannot happen until the preparations mine. Arming off
    /// transfers alone pointed at the wrong one.
    @Test func aPreparationsWindowWinsOverALaterTransfersWindow() {
        let preparations = MigrationDerivations.preparationRows(
            statuses: [Self.status(id: 0, kind: .preparation(layer: 0, index: 0), state: .proved, scheduledHeight: 3_000_000)],
            clock: Self.clock
        ) ?? []
        let transfers = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), state: .proved, scheduledHeight: 3_000_100)],
            clock: Self.clock
        ) ?? []

        let next = Self.nextBroadcast(preparations: preparations, transfers: transfers)
        #expect(next?.kind == .splitBalance, "the preparation is what is actually due")
        #expect(next?.forwardETAMinutes == 0)
    }

    /// Once the preparations have mined, the transfer is the next broadcast again — the fix widens
    /// what the arm can see, it does not make preparations win forever.
    @Test func aMinedPreparationYieldsToTheTransfer() {
        let preparations = MigrationDerivations.preparationRows(
            statuses: [
                Self.status(id: 0, kind: .preparation(layer: 0, index: 0), state: .mined(height: 2_999_900), scheduledHeight: 3_000_000)
            ],
            clock: Self.clock
        ) ?? []
        let transfers = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), state: .proved, scheduledHeight: 3_000_100)],
            clock: Self.clock
        ) ?? []

        #expect(Self.nextBroadcast(preparations: preparations, transfers: transfers)?.kind == .transfer)
    }

    /// A row already on the wire needs no send window. Without this clause its ETA — which has by
    /// definition passed — makes it the earliest "pending" row, and the arm schedules a poke one
    /// notification-buffer later for work that is already done.
    @Test func aBroadcastingRowIsNotSomethingToPokeAbout() {
        let preparations = MigrationDerivations.preparationRows(
            statuses: [
                Self.status(id: 0, kind: .preparation(layer: 0, index: 0), state: .broadcast(txid: Data([1])), scheduledHeight: 2_999_000)
            ],
            clock: Self.clock
        ) ?? []
        let transfers = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.status(id: 1, kind: .transfer(crossing: 0), state: .proved, scheduledHeight: 3_000_100)],
            clock: Self.clock
        ) ?? []

        let next = Self.nextBroadcast(preparations: preparations, transfers: transfers)
        #expect(next?.kind == .transfer, "the in-flight preparation must not win on its elapsed window")
    }

    /// Nothing left to broadcast is a real answer — the arm retires the poke rather than leaving a
    /// stale one pointing at a finished run.
    @Test func aFullyMinedRunHasNothingToPokeAbout() {
        let preparations = MigrationDerivations.preparationRows(
            statuses: [
                Self.status(id: 0, kind: .preparation(layer: 0, index: 0), state: .mined(height: 2_999_900), scheduledHeight: 3_000_000)
            ],
            clock: Self.clock
        ) ?? []
        let transfers = MigrationDerivations.statusOnlyTransferRows(
            statuses: [
                Self.status(id: 1, kind: .transfer(crossing: 0), state: .mined(height: 2_999_950), scheduledHeight: 3_000_100)
            ],
            clock: Self.clock
        ) ?? []

        #expect(Self.nextBroadcast(preparations: preparations, transfers: transfers) == nil)
    }

    // MARK: - P4: the engine outlook's arming candidate (pure half)

    /// A `.prove` outlook arms at its own window.
    @Test func aProveOutlookArmsAtItsWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let date = MigrationDerivations.outlookCandidateDate(
            outlook: MigrationNextWork(height: 3_000_010, kind: .prove),
            clock: Self.clock,
            now: now
        )
        #expect(date == Self.clock.notificationDate(atHeight: 3_000_010, now: now))
    }

    /// A `.broadcast` outlook arms at its own window too. 2026-08-07: this is the case that used
    /// to be special — a broadcast outlook took the post-sync buffer's clamp so a poke could not
    /// invite a send the gate would refuse. With no timed gate left to refuse it, every kind arms
    /// alike, and this pins that the clamp really is gone rather than merely unreachable.
    @Test func aBroadcastOutlookArmsAtItsWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let date = MigrationDerivations.outlookCandidateDate(
            outlook: MigrationNextWork(height: 3_000_050, kind: .broadcast),
            clock: Self.clock,
            now: now
        )
        #expect(date == Self.clock.notificationDate(atHeight: 3_000_050, now: now))
    }

    /// `.rebuild`/`.replan` arm at their own windows as well — every kind is a plain candidate.
    @Test func userShapedOutlookKindsArmAtTheirWindows() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        for kind in [MigrationStepKind.rebuild, MigrationStepKind.replan] {
            let date = MigrationDerivations.outlookCandidateDate(
                outlook: MigrationNextWork(height: 3_000_020, kind: kind),
                clock: Self.clock,
                now: now
            )
            #expect(date == Self.clock.notificationDate(atHeight: 3_000_020, now: now))
        }
    }

    /// No outlook, no candidate — the arm's other three candidates decide alone.
    @Test func aNilOutlookContributesNoCandidate() {
        #expect(
            MigrationDerivations.outlookCandidateDate(
                outlook: nil,
                clock: Self.clock,
                now: Date(timeIntervalSince1970: 1_000_000)
            ) == nil
        )
    }
}
