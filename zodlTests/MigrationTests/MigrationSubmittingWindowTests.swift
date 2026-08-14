//
//  MigrationSubmittingWindowTests.swift
//  zodlTests
//
//  The ~7 seconds a migration transaction is ON THE WIRE (MOB-1466).
//
//  WHY THIS SUITE EXISTS. A user tapped a notification, Zodl opened, broadcast their note-split —
//  the transaction the entire schedule depends on — and told them "We'll notify you when to send."
//  Field log, one session, three lines apart:
//
//      +0.50s broadcasting migration tx 0 — headless send session
//      +0.58s BANNER -> inProgress  ·  why: submitting now
//      +7.67s broadcast result: success(txId: dd8792ff…)
//
//  Their question was "why did I need to open Zodl? This open feels wasted." It was the opposite.
//
//  The window had no representation because no DURABLE state can carry it: the engine writes
//  `.broadcast(txid:)` only once the submit RETURNS, so for the seconds the call is open every
//  durable read still says "ready". `isSubmitting` is that missing fact, and these tests pin the two
//  properties that made the previous attempt fail in the field:
//
//  1. it drives the row's spinner (the counterpart the banner was missing), and
//  2. it does NOT resurrect the `isBroadcasting` spinner that was deliberately removed.
//
//  Those two look contradictory and are not — see `isInFlight`'s doc. That distinction is the whole
//  design, so it is asserted rather than left to a reader's memory.
//

import Foundation
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationSubmittingWindowTests {
    private static func row(
        status: MigrationTransferRow.Status,
        isBroadcasting: Bool = false,
        isPreparing: Bool = false,
        isSubmitting: Bool = false
    ) -> MigrationTransferRow {
        MigrationTransferRow(
            id: "r",
            index: 0,
            amount: Zatoshi(1),
            status: status,
            hoursFromNow: 0,
            isBroadcasting: isBroadcasting,
            isPreparing: isPreparing,
            isSubmitting: isSubmitting,
            kind: .splitBalance
        )
    }

    /// The point of the whole change: while the submit call is open, the row is work in flight and
    /// spins — so the banner's "Keep Zodl open" has a counterpart one tap away.
    @Test func submittingRowIsInFlight() {
        #expect(Self.row(status: .active, isSubmitting: true).isInFlight)
    }

    /// …regardless of the durable status underneath it, which is exactly the problem it solves: the
    /// engine has not written anything yet, so the row still reads `.pending`/`.active`/`.overdue`
    /// from a moment ago.
    @Test func submittingWinsOverWhateverTheDurableStatusSays() {
        for status in [MigrationTransferRow.Status.pending, .active, .overdue] {
            #expect(Self.row(status: status, isSubmitting: true).isInFlight, "status \(status)")
        }
    }

    /// The exclusion that must NOT come back. `isBroadcasting` means SUBMITTED and awaiting mining —
    /// minutes of the chain's work, with the app free to close. A spinner there runs forever and
    /// teaches the user the wallet is broken (2026-08-01). Re-adding `isSubmitting` is a different
    /// window, and this test is what keeps the two from being conflated again.
    @Test func broadcastingAloneStillDoesNotSpin() {
        #expect(!Self.row(status: .active, isBroadcasting: true).isInFlight)
    }

    /// The proving spinner is untouched by any of this.
    @Test func preparingRowStillSpinsOnItsOwnTerms() {
        #expect(Self.row(status: .active, isPreparing: true).isInFlight)
        #expect(Self.row(status: .overdue, isPreparing: true).isInFlight)
        // …and still not on a row whose window has not opened — proving runs out of send order, so a
        // spinner on a "~16 mins" row claims the app is busy with something that will not move.
        #expect(!Self.row(status: .pending, isPreparing: true).isInFlight)
    }

    /// An idle row is idle. Guards against a future `isInFlight` that quietly becomes true-by-default.
    @Test func anOrdinaryRowIsNotInFlight() {
        #expect(!Self.row(status: .pending).isInFlight)
        #expect(!Self.row(status: .sent).isInFlight)
    }

    /// The snapshot carries the fact, so banner and timeline read ONE value. If this ever splits back
    /// into two reads, the two surfaces can disagree for the length of a submit — which is precisely
    /// how the last version of this bug was born.
    @Test func snapshotCarriesTheSubmittingFact() {
        let submitting = MigrationViewSnapshot(
            orchardRemaining: Zatoshi(1),
            ironwoodHeld: .zero,
            movedByDoneTransfers: .zero,
            doneTransfers: 0,
            totalTransfers: 9,
            transfers: [],
            summary: MigrationSummary.zero,
            banner: nil,
            preparations: [Self.row(status: .active)],
            planTotal: Zatoshi(900_000_000),
            isTorHoldActive: false,
            needsTorFirstRunChoice: false,
            isSubmitting: true,
            sessionOrdinal: 1
        )

        #expect(submitting.isSubmitting)
        #expect(!MigrationViewSnapshot.empty.isSubmitting, "a snapshot with no run is not submitting")
    }

    /// The collapsed Split Balance row takes the flag from the snapshot rather than from its parts —
    /// no preparation row can know a submit call is open.
    @Test func collapsedSplitRowInheritsSubmitting() {
        let parts = [Self.row(status: .active), Self.row(status: .pending)]

        let submitting = MigrationStatus.State.collapsedSplitRow(
            from: parts,
            transfers: [],
            isSubmitting: true
        )
        let idle = MigrationStatus.State.collapsedSplitRow(
            from: parts,
            transfers: [],
            isSubmitting: false
        )

        #expect(submitting.isSubmitting)
        #expect(submitting.isInFlight)
        #expect(!idle.isSubmitting)
        #expect(!idle.isInFlight, "the parts alone must never imply a submit is open")
    }
}
