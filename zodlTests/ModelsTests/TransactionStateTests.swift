//
//  TransactionStateTests.swift
//  zodlTests
//
//  MOB-1513 (E1): the transaction-history display amount (`TransactionState.netValue`, shared by
//  the transaction list `TransactionRowView` and the detail screen `TransactionDetailsView`) adopts
//  Android's migration-self-send fallback: a transaction with no counted sent OR received notes
//  shows `totalReceived` — the real amount that crossed the Orchard -> Ironwood turnstile — instead
//  of the fee-collapsed net. All other transaction kinds keep at least one note, so they are
//  unaffected. Pure model logic, no shared/global state -> no `.serialized`.
//

import Testing
import Foundation
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct TransactionStateTests {
    /// The migration shape: a self-send whose net value collapses to (roughly) the fee, with no
    /// counted sent or received notes but a real `totalReceived`. The display amount must be the
    /// crossing amount (`totalReceived`), not the misleading fee-collapsed net (`zecAmount`).
    @Test func migrationSelfSendWithNoNotesDisplaysTotalReceived() {
        var transaction = TransactionState(
            fee: Zatoshi(10_000),
            id: "migration-crossing",
            status: .paid,
            zecAmount: Zatoshi(10_000),
            isSentTransaction: true
        )
        transaction.sentNoteCount = 0
        transaction.receivedNoteCount = 0
        transaction.totalReceived = Zatoshi(25_000_000)

        #expect(transaction.netValue == Zatoshi(25_000_000).atLeastThreeDecimalsZashiFormatted())
        #expect(transaction.netValue != Zatoshi(10_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// An ordinary send keeps at least one sent note, so the fallback must NOT apply — the display
    /// stays the fee-collapsed net (`zecAmount`), even when `totalReceived` (the change) is present.
    @Test func ordinarySendKeepsNetValueUnchanged() {
        var transaction = TransactionState(
            fee: Zatoshi(10_000),
            id: "ordinary-send",
            status: .paid,
            zecAmount: Zatoshi(25_000_000),
            isSentTransaction: true
        )
        transaction.sentNoteCount = 1
        transaction.receivedNoteCount = 0
        transaction.totalReceived = Zatoshi(24_990_000)

        #expect(transaction.netValue == Zatoshi(25_000_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// An ordinary receive keeps at least one received note, so the fallback must NOT apply — the
    /// display stays `zecAmount`.
    @Test func ordinaryReceiveKeepsNetValueUnchanged() {
        var transaction = TransactionState(
            fee: Zatoshi(10_000),
            id: "ordinary-receive",
            status: .received,
            zecAmount: Zatoshi(25_000_000),
            isSentTransaction: false
        )
        transaction.sentNoteCount = 0
        transaction.receivedNoteCount = 1

        #expect(transaction.netValue == Zatoshi(25_000_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// Guard: the note-less shape with NO `totalReceived` (nothing to show) falls back to the net
    /// value rather than a blank — the fallback only takes effect when the crossing amount exists.
    @Test func noNotesWithoutTotalReceivedFallsBackToNetValue() {
        var transaction = TransactionState(
            fee: Zatoshi(10_000),
            id: "no-notes-no-total",
            status: .paid,
            zecAmount: Zatoshi(10_000),
            isSentTransaction: true
        )
        transaction.sentNoteCount = 0
        transaction.receivedNoteCount = 0
        transaction.totalReceived = nil

        #expect(transaction.netValue == Zatoshi(10_000).atLeastThreeDecimalsZashiFormatted())
    }
}
