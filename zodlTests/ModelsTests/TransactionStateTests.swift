//
//  TransactionStateTests.swift
//  zodlTests
//
//  Covers the self-transfer display logic on TransactionState (Models/TransactionState.swift): a
//  transaction sent to the user's own wallet -- a manual send to one's own address, or the
//  Orchard -> Ironwood migration crossing -- nets to exactly -fee (the SDK's per-account balance
//  delta), so naively rendering `zecAmount` would show the fee instead of the amount that
//  actually moved. `TransactionState.isSelfTransfer` detects this shape (the fee-collapsed net,
//  with the SDK's note-count shape as a fallback for rows whose fee isn't recorded yet), and
//  `resolvedAmount` -- surfaced through `netValue` and `amountWithoutFee` -- substitutes the
//  amount deliberately addressed to the user's own address, falling back to `totalReceived` when
//  per-output detail isn't available (the dedicated migration path has none; its full crossing
//  amount mirrors Android's TransactionRepository fallback). Pure model logic, no shared/global
//  state -> no `.serialized`.
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
        fee: Zatoshi? = Zatoshi(10_000),
        totalSpent: Zatoshi? = nil,
        totalReceived: Zatoshi? = nil
    ) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
            accountUUID: testAccountUUID,
            blockTime: 1_699_290_621,
            expiryHeight: nil,
            fee: fee,
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

    /// An output paying an explicit address -- the deliberately-sent portion of a self-send.
    /// `isChange` is a parameter because the two are independent in the SDK's data: a transparent
    /// change or ephemeral output carries an address *and* is change (see
    /// `transparentChangeOutputIsExcludedFromExternalTotal`).
    private func addressedOutput(
        value: Zatoshi,
        pool: ZcashTransaction.Output.Pool = .orchard,
        isChange: Bool = false,
        index: Int = 0
    ) -> ZcashTransaction.Output {
        ZcashTransaction.Output(
            rawID: Data([0x01, 0x02, 0x03, 0x04]),
            pool: pool,
            index: index,
            fromAccount: nil,
            recipient: TransactionRecipient.address(Recipient.transparent(TransparentAddress(validatedEncoding: "tFixtureSelfSend"))),
            value: value,
            isChange: isChange,
            memo: nil
        )
    }

    /// A wallet-internal output (e.g. shielded change, or an Orchard -> Ironwood migration leg) --
    /// the DB reports no address for it, so it must be excluded from `externalOutputsTotal`.
    private func internalOutput(value: Zatoshi) -> ZcashTransaction.Output {
        ZcashTransaction.Output(
            rawID: Data([0x01, 0x02, 0x03, 0x04]),
            pool: .orchard,
            index: 1,
            fromAccount: nil,
            recipient: TransactionRecipient.internalAccount(testAccountUUID),
            value: value,
            isChange: true,
            memo: nil
        )
    }

    // MARK: - SDK wiring

    /// The SDK-backed init must carry the transaction's note counts onto the state rather than
    /// leaving them at their struct defaults. `sentNoteCount` and `receivedNoteCount` are given
    /// distinct, non-default values here, so deleting either wiring line in
    /// `TransactionState.init(transaction:)` (`sentNoteCount = transaction.sentNoteCount` /
    /// `receivedNoteCount = transaction.receivedNoteCount`) makes the corresponding property fall
    /// back to 0 and fails this test - unlike asserting against 0, which those defaults would
    /// satisfy whether or not the wiring exists.
    @Test func noteCountsAreWiredFromSDKTransaction() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 3,
                receivedNoteCount: 2,
                value: Zatoshi(25_000_000)
            )
        )

        #expect(state.sentNoteCount == 3)
        #expect(state.receivedNoteCount == 2)
    }

    // MARK: - Migration shape (the note-count fallback)

    /// The migration shape: a self-send whose net value collapses to the fee, with no counted
    /// sent or received notes, no per-output detail (an older/rescanned row), but a real
    /// `totalReceived`. netValue must show the crossing amount (`totalReceived`), not the
    /// misleading fee-collapsed net (`zecAmount`).
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

    /// A shielding transaction keeps the `totalSpent` path even with 0/0 note counts and both
    /// totals set: that branch has priority and must be checked before the self-transfer
    /// fallback. `totalReceived` is deliberately a different value, so an ordering bug (fallback
    /// checked first) would be caught by the assertion below.
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

    /// A shielding transaction has the same fee-collapsed shape as a self-transfer (its balance
    /// delta is exactly -fee, since the funds stay in the account and only change pool), so the
    /// predicate must exclude it explicitly. Without the guard, `resolvedAmount` still behaves --
    /// it checks shielding first -- but `amountWithoutFee` branches on `isSelfTransfer` before
    /// delegating and would silently start returning `totalSpent` instead of `zecAmount - fee`.
    @Test func shieldingTransactionIsNotASelfTransfer() {
        let state = TransactionState(
            transaction: overview(
                isShielding: true,
                sentNoteCount: 0,
                receivedNoteCount: 0,
                value: Zatoshi(-10_000),
                fee: Zatoshi(10_000),
                totalSpent: Zatoshi(1_000_000),
                totalReceived: Zatoshi(990_000)
            )
        )

        #expect(state.isShieldingTransaction)
        #expect(state.zecAmount == state.fee)
        #expect(!state.isSelfTransfer)
        #expect(state.amountWithoutFee == .zero)
    }

    /// Guard hardening: a note-less (0/0) shape whose `totalReceived` is `.zero` — the same shape
    /// the swap-deposit initialiser produces — must stay on the `zecAmount` path rather than
    /// misreport a zero crossing amount. `zecAmount` is deliberately non-zero here, so a guard
    /// that checks presence alone (not `> 0`) would return the zero `totalReceived` instead and
    /// be caught by the assertion below.
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
    }

    // MARK: - Manual self-send (the MOB-1580 repro shape)

    /// A manual send to one's own address: the net value collapses to the fee (a self-transfer),
    /// but per-output detail is available. netValue must show the amount deliberately addressed
    /// to the user's own address, not the fee, and not the coarser `totalReceived` (which also
    /// includes the wallet-internal change output).
    @Test func manualSelfSendWithOutputsDisplaysAddressedAmount() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 1,
                receivedNoteCount: 1,
                value: Zatoshi(-30_000),
                fee: Zatoshi(30_000),
                totalSpent: Zatoshi(16_494_726),
                totalReceived: Zatoshi(16_464_726)
            ),
            outputs: [
                addressedOutput(value: Zatoshi(12_000_000)),
                internalOutput(value: Zatoshi(4_464_726))
            ]
        )

        #expect(state.netValue == Zatoshi(12_000_000).atLeastThreeDecimalsZashiFormatted())
        #expect(state.netValue != Zatoshi(30_000).atLeastThreeDecimalsZashiFormatted())
        #expect(state.netValue != Zatoshi(16_464_726).atLeastThreeDecimalsZashiFormatted())
    }

    /// Same repro shape, but with 0/0 note counts (the note-less shape some rows report): the
    /// addressed-output total still wins over the `totalReceived` fallback, since per-output
    /// detail is available.
    @Test func manualSelfSendWithOutputsAndNoNotesDisplaysAddressedAmount() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 0,
                receivedNoteCount: 0,
                value: Zatoshi(-30_000),
                fee: Zatoshi(30_000),
                totalSpent: Zatoshi(16_494_726),
                totalReceived: Zatoshi(16_464_726)
            ),
            outputs: [
                addressedOutput(value: Zatoshi(12_000_000)),
                internalOutput(value: Zatoshi(4_464_726))
            ]
        )

        #expect(state.netValue == Zatoshi(12_000_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// Change is excluded from `externalOutputsTotal` by its `isChange` flag, not merely by the
    /// absence of an address. Shielded change carries no address, but the SDK resolves an address
    /// row for every transparent output it receives -- including internal-scope change and
    /// ephemeral outputs -- so an address-only filter would fold transparent change back into the
    /// total and display the sent amount plus the change that returned.
    @Test func transparentChangeOutputIsExcludedFromExternalTotal() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 1,
                receivedNoteCount: 1,
                value: Zatoshi(-30_000),
                fee: Zatoshi(30_000),
                totalSpent: Zatoshi(16_494_726),
                totalReceived: Zatoshi(16_464_726)
            ),
            outputs: [
                addressedOutput(value: Zatoshi(12_000_000)),
                addressedOutput(value: Zatoshi(4_464_726), pool: .transaparent, isChange: true, index: 1)
            ]
        )

        #expect(state.isSelfTransfer)
        #expect(state.externalOutputsTotal == Zatoshi(12_000_000))
        #expect(state.netValue == Zatoshi(12_000_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// Degradation: a self-transfer whose outputs aren't available at all (empty array) falls
    /// back to `totalReceived`, same as the note-less migration shape.
    @Test func selfTransferWithNoOutputsAvailableFallsBackToTotalReceived() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 1,
                receivedNoteCount: 1,
                value: Zatoshi(-30_000),
                fee: Zatoshi(30_000),
                totalSpent: Zatoshi(16_494_726),
                totalReceived: Zatoshi(16_464_726)
            ),
            outputs: []
        )

        #expect(state.netValue == Zatoshi(16_464_726).atLeastThreeDecimalsZashiFormatted())
    }

    // MARK: - Guards: ordinary sends/receives must not be treated as self-transfers

    /// An ordinary send keeps at least one sent note and its net value is NOT just the fee, so
    /// neither self-transfer arm applies, even when `totalReceived` (change) is present — the
    /// display stays the fee-collapsed net (`zecAmount`). `totalReceived` is deliberately
    /// different from `zecAmount`, so a broken `sentNoteCount` wiring (SDK -> TransactionState)
    /// would be caught here.
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

    /// An ordinary external send (the net value is NOT just the fee) must keep showing
    /// `zecAmount`, even though its outputs include one addressed output and one internal
    /// (change) output -- the self-transfer predicate must not fire just because outputs exist.
    @Test func ordinaryExternalSendIsUnchanged() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 1,
                receivedNoteCount: 0,
                value: Zatoshi(-12_030_000),
                fee: Zatoshi(30_000),
                totalReceived: Zatoshi(4_464_726)
            ),
            outputs: [
                addressedOutput(value: Zatoshi(12_000_000)),
                internalOutput(value: Zatoshi(4_464_726))
            ]
        )

        #expect(state.netValue == Zatoshi(12_030_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// A received transaction whose value coincidentally equals the fee must stay on the
    /// `zecAmount` path -- `isSentTransaction` gates the whole self-transfer check.
    @Test func receivedTransactionMatchingFeeIsUnchanged() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 0,
                receivedNoteCount: 1,
                value: Zatoshi(30_000),
                fee: Zatoshi(30_000)
            )
        )

        #expect(!state.isSentTransaction)
        #expect(state.netValue == Zatoshi(30_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// The non-SDK initialisers (a pending send, a swap deposit) never touch the note-count
    /// fields, so they must default to 0 and keep compiling unchanged. Both produce a 0/0
    /// "note-less" shape too; the pending send has no `totalReceived` at all and the swap deposit
    /// sets it to `.zero` (and its `fee` to `.zero`, excluded by the fee-arm's `> 0` guard), so
    /// both correctly stay on the `zecAmount` path.
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

    // MARK: - The note-count arm operates independently of the fee-based arm

    /// When `fee` is nil (not yet recorded), the note-count arm alone must still catch a
    /// self-transfer: 0/0 counts with a real `totalReceived` falls back to it.
    @Test func nilFeeWithNoNotesStillFallsBackToTotalReceived() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 0,
                receivedNoteCount: 0,
                value: Zatoshi(-10_000),
                fee: nil,
                totalReceived: Zatoshi(25_000_000)
            )
        )

        #expect(state.fee == nil)
        #expect(state.netValue == Zatoshi(25_000_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// When `fee` is nil AND at least one note is counted, neither arm fires -- the transaction
    /// keeps showing `zecAmount`.
    @Test func nilFeeWithNotesKeepsZecAmountPath() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 1,
                receivedNoteCount: 1,
                value: Zatoshi(-12_030_000),
                fee: nil,
                totalReceived: Zatoshi(4_464_726)
            )
        )

        #expect(state.fee == nil)
        #expect(state.netValue == Zatoshi(12_030_000).atLeastThreeDecimalsZashiFormatted())
    }

    // MARK: - amountWithoutFee (send-again prefill)

    /// For a self-transfer, `amountWithoutFee` must match the resolved display amount (not
    /// `zecAmount - fee`, which would be 0 for a self-send), so send-again prefills the amount
    /// the user actually meant to move.
    @Test func amountWithoutFeeForSelfTransferMatchesResolvedAmount() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 1,
                receivedNoteCount: 1,
                value: Zatoshi(-30_000),
                fee: Zatoshi(30_000),
                totalSpent: Zatoshi(16_494_726),
                totalReceived: Zatoshi(16_464_726)
            ),
            outputs: [
                addressedOutput(value: Zatoshi(12_000_000)),
                internalOutput(value: Zatoshi(4_464_726))
            ]
        )

        #expect(state.amountWithoutFee == Zatoshi(12_000_000))
    }

    /// For an ordinary send, `amountWithoutFee` is unchanged: `zecAmount - fee`. The addressed
    /// output is deliberately NOT `zecAmount - fee`, so the two branches of `amountWithoutFee`
    /// yield different numbers and the assertion actually discriminates between them -- with a
    /// matching value the test would pass even if `isSelfTransfer` wrongly fired here.
    @Test func amountWithoutFeeForOrdinarySendIsUnchanged() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 1,
                receivedNoteCount: 0,
                value: Zatoshi(-12_030_000),
                fee: Zatoshi(30_000),
                totalReceived: Zatoshi(4_464_726)
            ),
            outputs: [
                addressedOutput(value: Zatoshi(11_000_000)),
                internalOutput(value: Zatoshi(4_464_726))
            ]
        )

        #expect(!state.isSelfTransfer)
        #expect(state.amountWithoutFee == Zatoshi(12_000_000))
        #expect(state.amountWithoutFee != state.externalOutputsTotal)
    }

    // MARK: - SDK assembly (SDKSynchronizerClient.transactionState)

    /// The SDK call site must feed each transaction's outputs into `TransactionState`. Every
    /// assertion here covers a field derived from `outputs` at that seam, because dropping the
    /// wiring degrades silently -- the display amount falls back to `totalReceived` (see
    /// `selfTransferWithNoOutputsAvailableFallsBackToTotalReceived`) instead of failing. The
    /// transparent-pool output also pins `hasTransparentOutputs` and the recipient derivation,
    /// which now reads `outputs` rather than issuing a second query for the same rows.
    @Test func sdkAssemblyWiresOutputsIntoTransactionState() {
        let state = SDKSynchronizerClient.transactionState(
            from: overview(
                sentNoteCount: 1,
                receivedNoteCount: 1,
                value: Zatoshi(-30_000),
                fee: Zatoshi(30_000),
                totalSpent: Zatoshi(16_494_726),
                totalReceived: Zatoshi(16_464_726)
            ),
            outputs: [
                addressedOutput(value: Zatoshi(12_000_000), pool: .transaparent),
                internalOutput(value: Zatoshi(4_464_726))
            ],
            currentChainTip: nil
        )

        #expect(state.externalOutputsTotal == Zatoshi(12_000_000))
        #expect(state.netValue == Zatoshi(12_000_000).atLeastThreeDecimalsZashiFormatted())
        #expect(state.hasTransparentOutputs)
        #expect(state.zAddress == "tFixtureSelfSend")
        #expect(state.isTransparentRecipient)
        #expect(state.rawID == Data([0x01, 0x02, 0x03, 0x04]))
    }

    /// The mirror of the above: with no outputs, every outputs-derived field stays at its default
    /// and the display amount degrades to `totalReceived`. Together the two tests pin the seam in
    /// both directions, so a dropped `outputs:` argument fails here rather than shipping.
    @Test func sdkAssemblyWithoutOutputsLeavesDerivedFieldsAtDefaults() {
        let state = SDKSynchronizerClient.transactionState(
            from: overview(
                sentNoteCount: 1,
                receivedNoteCount: 1,
                value: Zatoshi(-30_000),
                fee: Zatoshi(30_000),
                totalSpent: Zatoshi(16_494_726),
                totalReceived: Zatoshi(16_464_726)
            ),
            outputs: [],
            currentChainTip: nil
        )

        #expect(state.externalOutputsTotal == .zero)
        #expect(!state.hasTransparentOutputs)
        #expect(state.zAddress == nil)
        #expect(!state.isTransparentRecipient)
        #expect(state.netValue == Zatoshi(16_464_726).atLeastThreeDecimalsZashiFormatted())
    }
}
