//
//  TransactionStateTests.swift
//  zodlTests
//
//  Covers the self-transfer display logic on TransactionState (Models/TransactionState.swift): a
//  transaction sent to the user's own wallet -- a manual send to one's own address, or the
//  Orchard -> Ironwood migration crossing -- nets to exactly -fee (the SDK's per-account balance
//  delta), so naively rendering `zecAmount` would show the fee instead of the amount that
//  actually moved. `TransactionState.isSelfTransfer` detects that shape from the recorded fee,
//  falling back to the outputs when no fee is recorded, and `resolvedAmount` -- surfaced through
//  `netValue` and `amountWithoutFee` -- substitutes the amount deliberately addressed to the
//  user's own address, or `totalReceived` when per-output detail isn't available. Both
//  substitutes are output face values, so the fee is added back on to match `zecAmount`, which
//  every other send row displays and which already includes it -- see
//  `selfSendAndExternalSendDisplayTheSameTotalForTheSamePayment`.
//
//  Two SDK fields look usable here and are not, each with a test naming it: the note counts are
//  device-local (`ordinarySendSeenFromAnotherDeviceIsNotASelfTransfer`) and `isChange` is set on a
//  self-send's own payment output whenever the transaction was scanned rather than created locally
//  (`selfSendPaymentOutputFlaggedAsChangeByScanningIsStillCounted`). Both produce a display that is
//  correct on the sending device and wrong everywhere else, so both are excluded from detection.
//
//  Pure model logic, no shared/global state -> no `.serialized`.
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
    /// `isChange` is a parameter because upstream sets that flag on a self-send's payment output
    /// whenever the transaction was scanned rather than created locally (see
    /// `selfSendPaymentOutputFlaggedAsChangeByScanningIsStillCounted`), so both values occur for
    /// the very same output depending on which device is looking.
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

    // MARK: - Migration shape

    /// The migration shape: a self-send whose net value collapses to the fee, with no per-output
    /// detail (an older/rescanned row) but a recorded fee and a real `totalReceived`. The recorded
    /// fee matches the balance delta, so it is a self-transfer, and netValue must show the crossing
    /// amount (`totalReceived`, plus the fee) rather than the misleading fee-collapsed net.
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
        #expect(state.netValue == Zatoshi(25_010_000).atLeastThreeDecimalsZashiFormatted())
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

        #expect(state.netValue == Zatoshi(12_030_000).atLeastThreeDecimalsZashiFormatted())
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

        #expect(state.netValue == Zatoshi(12_030_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// The self-send as it looks on a device that SCANNED the transaction rather than creating it
    /// -- which includes the sending device once it scans the block containing its own send.
    ///
    /// Upstream marks a received output as change when the receiving account also spent in the
    /// same transaction (`scanning.rs`: `spent_from_accounts.contains(key.account_id())`, whose
    /// comment names "notes sent from one account to itself" as an intended case). So the payment
    /// output arrives here flagged `isChange`, and `externalOutputsTotal` must count it anyway:
    /// filtering on that flag empties the sum and drops the row onto the `totalReceived` fallback,
    /// which reports payment plus change -- the 0.03 self-send that displayed 0.064.
    @Test func selfSendPaymentOutputFlaggedAsChangeByScanningIsStillCounted() {
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
                addressedOutput(value: Zatoshi(12_000_000), isChange: true),
                internalOutput(value: Zatoshi(4_464_726))
            ]
        )

        #expect(state.isSelfTransfer)
        #expect(state.externalOutputsTotal == Zatoshi(12_000_000))
        #expect(state.netValue == Zatoshi(12_030_000).atLeastThreeDecimalsZashiFormatted())
        // Not payment + change + fee, which is what dropping to the fallback produces.
        #expect(state.netValue != Zatoshi(16_494_726).atLeastThreeDecimalsZashiFormatted())
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

        #expect(state.netValue == Zatoshi(16_494_726).atLeastThreeDecimalsZashiFormatted())
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

    // MARK: - Detection must not depend on which device created the transaction

    /// The regression this suite exists to prevent. `sent_note_count` counts rows in the SDK's
    /// `sent_notes` table, which only the device that *created* the transaction has, and
    /// `received_note_count` excludes change. So an ordinary external send presents as 0/0 with a
    /// positive `totalReceived` (its change) on every other device holding the same wallet -- the
    /// exact shape a genuine self-transfer has. Detection must therefore ignore the note counts
    /// entirely: the recorded fee settles it, and this send's balance delta is not the fee.
    @Test func ordinarySendSeenFromAnotherDeviceIsNotASelfTransfer() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 0,
                receivedNoteCount: 0,
                value: Zatoshi(-12_030_000),
                fee: Zatoshi(30_000),
                totalSpent: Zatoshi(16_494_726),
                totalReceived: Zatoshi(4_464_726)
            ),
            outputs: [
                addressedOutput(value: Zatoshi(12_000_000)),
                internalOutput(value: Zatoshi(4_464_726))
            ]
        )

        #expect(!state.isSelfTransfer)
        #expect(state.netValue == Zatoshi(12_030_000).atLeastThreeDecimalsZashiFormatted())
        // Not the change, which is what the note-count shape used to resolve to.
        #expect(state.netValue != Zatoshi(4_494_726).atLeastThreeDecimalsZashiFormatted())
    }

    /// Same, with no per-output detail to fall back on either: a recorded fee that the balance
    /// delta does not match is conclusive on its own.
    @Test func ordinarySendSeenFromAnotherDeviceWithoutOutputsIsNotASelfTransfer() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 0,
                receivedNoteCount: 0,
                value: Zatoshi(-12_030_000),
                fee: Zatoshi(30_000),
                totalReceived: Zatoshi(4_464_726)
            ),
            outputs: []
        )

        #expect(state.externalOutputsTotal == nil)
        #expect(!state.isSelfTransfer)
        #expect(state.netValue == Zatoshi(12_030_000).atLeastThreeDecimalsZashiFormatted())
    }

    // MARK: - The outputs fallback, for rows whose fee is not recorded

    /// With no recorded fee, detection falls back to the outputs: every output here is
    /// wallet-internal, so nothing was paid to an address and the transaction is a self-transfer
    /// (the Orchard -> Ironwood migration shape). It resolves to `totalReceived`, and adds no fee
    /// because none is known.
    @Test func nilFeeWithOnlyInternalOutputsFallsBackToTotalReceived() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 0,
                receivedNoteCount: 0,
                value: Zatoshi(-10_000),
                fee: nil,
                totalReceived: Zatoshi(25_000_000)
            ),
            outputs: [internalOutput(value: Zatoshi(25_000_000))]
        )

        #expect(state.fee == nil)
        #expect(state.externalOutputsTotal == .zero)
        #expect(state.isSelfTransfer)
        #expect(state.netValue == Zatoshi(25_000_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// With no recorded fee AND an output paying an address, the fallback must not fire -- money
    /// left the wallet.
    @Test func nilFeeWithAddressedOutputIsNotASelfTransfer() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 0,
                receivedNoteCount: 0,
                value: Zatoshi(-12_030_000),
                fee: nil,
                totalReceived: Zatoshi(4_464_726)
            ),
            outputs: [
                addressedOutput(value: Zatoshi(12_000_000)),
                internalOutput(value: Zatoshi(4_464_726))
            ]
        )

        #expect(!state.isSelfTransfer)
        #expect(state.netValue == Zatoshi(12_030_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// With no recorded fee and no per-output detail, nothing can be concluded, so the transaction
    /// stays on the `zecAmount` path. This is the deliberate cost of dropping the note counts: a
    /// migration crossing that has neither a fee nor output rows shows its fee-collapsed net until
    /// one of the two lands. Guessing instead is what broke ordinary sends on a second device.
    @Test func nilFeeWithoutOutputDetailKeepsZecAmountPath() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 0,
                receivedNoteCount: 0,
                value: Zatoshi(-10_000),
                fee: nil,
                totalReceived: Zatoshi(25_000_000)
            ),
            outputs: []
        )

        #expect(state.fee == nil)
        #expect(state.externalOutputsTotal == nil)
        #expect(!state.isSelfTransfer)
        #expect(state.netValue == Zatoshi(10_000).atLeastThreeDecimalsZashiFormatted())
    }

    // MARK: - amountWithoutFee (send-again prefill)

    /// For a self-transfer, `amountWithoutFee` strips the fee off the resolved display amount
    /// rather than off `zecAmount` (which is the fee alone, and would give 0), so send-again
    /// prefills the payment the user actually meant to move -- 12.000, not the 12.030 shown on
    /// the row. This is the same relationship an ordinary send has between the two properties.
    @Test func amountWithoutFeeForSelfTransferStripsFeeFromResolvedAmount() {
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

    // MARK: - Fee convention shared with ordinary sends

    /// The whole point of adding the fee back on in `resolvedAmount`: the same 12 ZEC payment
    /// with the same 30_000 fee must display identically whether it went to someone else or back
    /// to the user's own address. `zecAmount` (the balance delta) is fee-inclusive for an ordinary
    /// send, while `externalOutputsTotal` is an output face value and is not, so without the
    /// adjustment these two rows would read 12.030 and 12.000 with nothing on screen to explain
    /// the difference.
    @Test func selfSendAndExternalSendDisplayTheSameTotalForTheSamePayment() {
        let selfSend = TransactionState(
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

        let externalSend = TransactionState(
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

        #expect(selfSend.isSelfTransfer)
        #expect(!externalSend.isSelfTransfer)
        #expect(selfSend.netValue == externalSend.netValue)
        #expect(selfSend.netValue == Zatoshi(12_030_000).atLeastThreeDecimalsZashiFormatted())
        // ...and both strip the same fee back off for the send-again prefill.
        #expect(selfSend.amountWithoutFee == externalSend.amountWithoutFee)
        #expect(selfSend.amountWithoutFee == Zatoshi(12_000_000))
    }

    /// Degenerate self-transfer: detected by the fee arm, but with no outputs and no
    /// `totalReceived` to resolve against, so `resolvedAmount` falls through to `zecAmount` -- the
    /// fee. `amountWithoutFee` must still subtract it and land on zero rather than prefilling the
    /// send form with the fee.
    @Test func amountWithoutFeeForUnresolvableSelfTransferIsZero() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 1,
                receivedNoteCount: 1,
                value: Zatoshi(-30_000),
                fee: Zatoshi(30_000)
            ),
            outputs: []
        )

        #expect(state.isSelfTransfer)
        #expect(state.externalOutputsTotal == nil)
        #expect(state.totalReceived == nil)
        #expect(state.amountWithoutFee == .zero)
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
        #expect(state.netValue == Zatoshi(12_030_000).atLeastThreeDecimalsZashiFormatted())
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

        #expect(state.externalOutputsTotal == nil)
        #expect(!state.hasTransparentOutputs)
        #expect(state.zAddress == nil)
        #expect(!state.isTransparentRecipient)
        #expect(state.netValue == Zatoshi(16_494_726).atLeastThreeDecimalsZashiFormatted())
    }
}
