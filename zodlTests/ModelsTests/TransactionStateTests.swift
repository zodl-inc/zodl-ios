//
//  TransactionStateTests.swift
//  zodlTests
//
//  Covers the migration self-send display fallback on TransactionState.netValue
//  (Models/TransactionState.swift). An Orchard -> Ironwood turnstile transfer is a self-send:
//  its net value collapses to just the fee, so without the fallback the transaction list and
//  detail screen would show a fee-sized amount instead of the amount that actually crossed the
//  turnstile. When the SDK reports no counted sent or received notes, netValue falls back to
//  totalReceived (the real crossing amount), mirroring Android's TransactionRepository. Pure
//  model logic, no shared/global state -> no `.serialized`.
//

import Testing
import Foundation
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct TransactionStateTests {
    private let testAccountUUID = AccountUUID(id: [UInt8](repeating: 0, count: 16))

    private func overview(
        isShielding: Bool = false,
        sentNoteCount: Int,
        receivedNoteCount: Int,
        value: Zatoshi,
        totalSpent: Zatoshi? = nil,
        totalReceived: Zatoshi? = nil
    ) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
            accountUUID: testAccountUUID,
            blockTime: 1_699_290_621,
            expiryHeight: nil,
            fee: Zatoshi(10_000),
            index: nil,
            isShielding: isShielding,
            hasChange: false,
            memoCount: 0,
            minedHeight: BlockHeight(1),
            raw: nil,
            rawID: Data([0x01, 0x02, 0x03, 0x04]),
            receivedNoteCount: receivedNoteCount,
            sentNoteCount: sentNoteCount,
            value: value,
            isExpiredUmined: nil,
            totalSpent: totalSpent,
            totalReceived: totalReceived
        )
    }

    /// The migration shape: a self-send whose net value collapses to the fee, with no counted
    /// sent or received notes but a real `totalReceived`. netValue must show the crossing amount
    /// (`totalReceived`), not the misleading fee-collapsed net (`zecAmount`).
    @Test func migrationSelfSendWithNoNotesDisplaysTotalReceived() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 0,
                receivedNoteCount: 0,
                value: Zatoshi(-10_000),
                totalReceived: Zatoshi(25_000_000)
            )
        )

        #expect(state.sentNoteCount == 0)
        #expect(state.receivedNoteCount == 0)
        #expect(state.netValue == Zatoshi(25_000_000).atLeastThreeDecimalsZashiFormatted())
        #expect(state.netValue != state.zecAmount.atLeastThreeDecimalsZashiFormatted())
    }

    /// A shielding transaction keeps the `totalSpent` path even with 0/0 note counts: that
    /// branch has priority and must be checked before the note-count fallback. `totalReceived`
    /// is deliberately a different value, so an ordering bug (fallback checked first) would be
    /// caught by the assertion below.
    @Test func shieldingTransactionKeepsTotalSpentPathEvenWithNoNotes() {
        let state = TransactionState(
            transaction: overview(
                isShielding: true,
                sentNoteCount: 0,
                receivedNoteCount: 0,
                value: Zatoshi(-10_000),
                totalSpent: Zatoshi(1_000_000),
                totalReceived: Zatoshi(990_000)
            )
        )

        #expect(state.isShieldingTransaction)
        #expect(state.netValue == Zatoshi(1_000_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// Guard hardening: a note-less (0/0) shape whose `totalReceived` is `.zero` — the same shape
    /// the swap-deposit initialiser produces — must stay on the `zecAmount` path rather than
    /// misreport a zero crossing amount. `zecAmount` is deliberately non-zero here so the two
    /// paths are distinguishable: a guard that checks presence alone (not `> 0`) would return the
    /// zero `totalReceived` and fail the second assertion.
    @Test func noteslessStateWithZeroTotalReceivedKeepsZecAmountPath() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 0,
                receivedNoteCount: 0,
                value: Zatoshi(-10_000),
                totalReceived: .zero
            )
        )

        #expect(state.netValue == state.zecAmount.atLeastThreeDecimalsZashiFormatted())
        #expect(state.netValue != Zatoshi.zero.atLeastThreeDecimalsZashiFormatted())
    }

    /// The non-SDK initialisers (a pending send, a swap deposit) never touch the note-count
    /// fields, so they must default to 0 and keep compiling unchanged. Both produce a 0/0
    /// "note-less" shape too; the pending send has no `totalReceived` at all and the swap deposit
    /// sets it to `.zero`, so both correctly stay on the `zecAmount` path.
    @Test func nonSDKInitsDefaultNoteCountsToZeroAndKeepZecAmountPath() {
        let pendingSend = TransactionState(pendingSendId: "pending-send", zecAmount: Zatoshi(15_000_000))
        #expect(pendingSend.sentNoteCount == 0)
        #expect(pendingSend.receivedNoteCount == 0)
        #expect(pendingSend.netValue == Zatoshi(15_000_000).atLeastThreeDecimalsZashiFormatted())

        let swapDeposit = TransactionState(
            depositAddress: "t1SwapDepositAddress",
            timestamp: 1_699_290_621,
            swapStatus: .pending
        )
        #expect(swapDeposit.sentNoteCount == 0)
        #expect(swapDeposit.receivedNoteCount == 0)
        #expect(swapDeposit.totalReceived == .zero)
        #expect(swapDeposit.netValue == Zatoshi.zero.atLeastThreeDecimalsZashiFormatted())
    }

    /// An ordinary send keeps at least one sent note, so the fallback must not apply, even when
    /// `totalReceived` (change) is present — the display stays the fee-collapsed net
    /// (`zecAmount`). `totalReceived` is deliberately different from `zecAmount`, so a broken
    /// `sentNoteCount` wiring (SDK -> TransactionState) would be caught here.
    @Test func ordinarySendWithNotesIsUnchanged() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 1,
                receivedNoteCount: 0,
                value: Zatoshi(-25_010_000),
                totalReceived: Zatoshi(5_000)
            )
        )

        #expect(state.sentNoteCount == 1)
        #expect(state.netValue == Zatoshi(25_010_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// Mirror case: an ordinary receive keeps at least one received note, so the fallback must
    /// not apply either. `totalReceived` is deliberately different from `zecAmount`, so a broken
    /// `receivedNoteCount` wiring would be caught here.
    @Test func ordinaryReceiveWithNotesIsUnchanged() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 0,
                receivedNoteCount: 1,
                value: Zatoshi(25_000_000),
                totalReceived: Zatoshi(24_500_000)
            )
        )

        #expect(state.receivedNoteCount == 1)
        #expect(state.netValue == Zatoshi(25_000_000).atLeastThreeDecimalsZashiFormatted())
    }
}
