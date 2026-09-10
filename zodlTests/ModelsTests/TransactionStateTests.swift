//
//  TransactionStateTests.swift
//  zodlTests
//
//  Covers `TransactionState.netValue` (Models/TransactionState.swift) for self-transfers - a
//  transaction whose sender and recipient are the same wallet. A self-transfer's SDK-reported
//  `value` (the account's balance delta) is exactly `-fee`: the amount sent out and the amount
//  that returns as change cancel each other out, leaving only the fee behind. `netValue`'s
//  default path (`zecAmount`, which is just `-value` for a sent transaction) therefore already
//  displays the fee correctly, with no special-casing required. There is deliberately no
//  note-count-based (or otherwise conditional) fallback to a larger "amount that actually moved" -
//  none exists, and these tests guard against one being reintroduced. Pure model logic, no
//  shared/global state -> no `.serialized`.
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
        totalReceived: Zatoshi? = nil,
        poolCrossingValue: Zatoshi? = nil,
        minedHeight: BlockHeight? = BlockHeight(1),
        zip318Kind: ZcashTransaction.Overview.ZIP318Kind = .notClassified
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
            minedHeight: minedHeight,
            raw: nil,
            rawID: Data([0x01, 0x02, 0x03, 0x04]),
            receivedNoteCount: receivedNoteCount,
            sentNoteCount: sentNoteCount,
            value: value,
            isExpiredUmined: nil,
            totalSpent: totalSpent,
            totalReceived: totalReceived,
            spentNoteCount: sentNoteCount,
            poolCrossingValue: poolCrossingValue,
            isTrusted: true,
            zip318Kind: zip318Kind
        )
    }

    // MARK: - ZIP 318 kind

    /// The SDK's classification must ride into the app model unchanged — the labels, the
    /// coins-swap icon, and the pending-balance correction all key on it.
    @Test func zip318KindFlowsThroughFromOverview() {
        let state = TransactionState(
            transaction: overview(sentNoteCount: 1, receivedNoteCount: 0, value: Zatoshi(-1), zip318Kind: .transfer)
        )
        #expect(state.zip318Kind == ZcashTransaction.Overview.ZIP318Kind.transfer)
    }

    /// The flag, exhaustively: only UNMINED preparation/transfer rows count. Mined migration
    /// rows are settled history; `.notClassified` is the absence of a decision and must never be
    /// treated as one; `.nonconforming` is a regular transaction. The flag no longer hides
    /// anything — it feeds the balance-breakdown sheet's pending correction (M3 B2).
    @Test func unminedMigrationRowsAreFlaggedMinedAndUnclassifiedAreNot() {
        typealias Kind = ZcashTransaction.Overview.ZIP318Kind
        let expectations: [(Kind, BlockHeight?, Bool)] = [
            (Kind.preparation, nil, true),
            (Kind.transfer, nil, true),
            (Kind.preparation, BlockHeight(100), false),
            (Kind.transfer, BlockHeight(100), false),
            (Kind.notClassified, nil, false),
            (Kind.nonconforming, nil, false)
        ]
        for (kind, minedHeight, isUnminedMigration) in expectations {
            let state = TransactionState(
                transaction: overview(sentNoteCount: 1, receivedNoteCount: 0, value: Zatoshi(-1), minedHeight: minedHeight, zip318Kind: kind)
            )
            #expect(
                state.isUnminedMigrationTransaction == isUnminedMigration,
                "kind \(kind), minedHeight \(String(describing: minedHeight)) expected isUnminedMigration == \(isUnminedMigration)"
            )
        }
    }

    /// A self-transfer just after it's created: the SDK already counts a sent note (the payment
    /// output) and a received note (the change), so `sentNoteCount`/`receivedNoteCount` are both
    /// 1. The balance delta (`value`) is `-10_000`, exactly `-fee`, so `zecAmount` is `10_000` and
    /// `netValue` must show that fee - not `totalReceived`, which stands in here for an unrelated,
    /// much larger figure that must NOT leak into the display.
    @Test func selfSendDisplaysTheFee() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 1,
                receivedNoteCount: 1,
                value: Zatoshi(-10_000),
                totalReceived: Zatoshi(16_464_726)
            )
        )

        #expect(state.netValue == Zatoshi(10_000).atLeastThreeDecimalsZashiFormatted())
        #expect(state.netValue != Zatoshi(16_464_726).atLeastThreeDecimalsZashiFormatted())
    }

    /// Guards the reported "value grew after confirmation" symptom: before the device scans the
    /// block that mines a self-transfer, the SDK counts a sent and a received note
    /// (`sentNoteCount`/`receivedNoteCount` = 1/1); once scanned, it reclassifies the payment
    /// output as change and reports no counted notes at all (0/0). Both states share the same
    /// `value` (`-10_000`, i.e. `-fee`) and the same `totalReceived`. Since `netValue` no longer
    /// branches on note counts, both states must show the identical fee-sized amount - the display
    /// must never change (let alone grow to `totalReceived`) as the transaction gets confirmed.
    @Test func selfSendDisplaysTheSameFeeBeforeAndAfterScanning() {
        let beforeScanning = TransactionState(
            transaction: overview(
                sentNoteCount: 1,
                receivedNoteCount: 1,
                value: Zatoshi(-10_000),
                totalReceived: Zatoshi(16_464_726)
            )
        )
        let afterScanning = TransactionState(
            transaction: overview(
                sentNoteCount: 0,
                receivedNoteCount: 0,
                value: Zatoshi(-10_000),
                totalReceived: Zatoshi(16_464_726)
            )
        )

        #expect(beforeScanning.netValue == afterScanning.netValue)
        #expect(beforeScanning.netValue == Zatoshi(10_000).atLeastThreeDecimalsZashiFormatted())
        #expect(afterScanning.netValue == Zatoshi(10_000).atLeastThreeDecimalsZashiFormatted())
        #expect(beforeScanning.netValue != Zatoshi(16_464_726).atLeastThreeDecimalsZashiFormatted())
        #expect(afterScanning.netValue != Zatoshi(16_464_726).atLeastThreeDecimalsZashiFormatted())
    }

    /// The Orchard -> Ironwood turnstile migration shape: a self-transfer with no counted sent or
    /// received notes (0/0) and a large `totalReceived` left over from the now-deleted fallback.
    /// `netValue` must still show only the fee (`10_000`), since a migration crossing is a
    /// self-transfer like any other - its balance delta is `-fee`, and no fallback remains to
    /// substitute `totalReceived` for it.
    @Test func ironwoodMigrationDisplaysTheFee() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 0,
                receivedNoteCount: 0,
                value: Zatoshi(-10_000),
                totalReceived: Zatoshi(25_000_000)
            )
        )

        #expect(state.netValue == Zatoshi(10_000).atLeastThreeDecimalsZashiFormatted())
        #expect(state.netValue != Zatoshi(25_000_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// An ordinary send to someone else: the balance delta is the sent amount plus the fee
    /// (`-25_010_000`), so `netValue` must show the full `25_010_000` - the amount the recipient
    /// gets plus the fee the sender paid - regardless of the unrelated `totalReceived` (change)
    /// also present on the transaction.
    @Test func ordinarySendDisplaysAmountPlusFee() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 1,
                receivedNoteCount: 0,
                value: Zatoshi(-25_010_000),
                totalReceived: Zatoshi(5_000)
            )
        )

        #expect(state.netValue == Zatoshi(25_010_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// A shielding transaction (transparent -> shielded) keeps its own `totalSpent`-based display
    /// even with no counted sent or received notes: the `isShieldingTransaction` branch is checked
    /// before the default path in `netValue`, so it must win regardless of note counts.
    @Test func shieldingTransactionDisplaysTotalSpent() {
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

    /// An ordinary receive: the balance delta is the full amount received (`25_000_000`), so
    /// `netValue` must show that amount, not the unrelated `totalReceived` figure also present on
    /// the transaction.
    @Test func ordinaryReceiveIsUnchanged() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 0,
                receivedNoteCount: 1,
                value: Zatoshi(25_000_000),
                totalReceived: Zatoshi(24_500_000)
            )
        )

        #expect(state.netValue == Zatoshi(25_000_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// The non-SDK initialisers - a pending send and a swap deposit - never go through
    /// `init(transaction:)`, so they're unaffected by this change. A pending send's `netValue` is
    /// simply its `zecAmount`. A swap deposit has no funds attributed to it yet (`totalReceived`
    /// is `.zero`), so its `netValue` is `Zatoshi.zero`, formatted like any other amount.
    @Test func nonSDKInitsAreUnchanged() {
        let pendingSend = TransactionState(pendingSendId: "pending-send", zecAmount: Zatoshi(15_000_000))
        #expect(pendingSend.netValue == Zatoshi(15_000_000).atLeastThreeDecimalsZashiFormatted())

        let swapDeposit = TransactionState(
            depositAddress: "t1SwapDepositAddress",
            timestamp: 1_699_290_621,
            swapStatus: .pending
        )
        #expect(swapDeposit.totalReceived == .zero)
        #expect(swapDeposit.netValue == Zatoshi.zero.atLeastThreeDecimalsZashiFormatted())
    }

    // MARK: - ZIP 318 labels (Figma "Transaction Statuses/Labels — Final Designs")

    /// A migration row's user-facing amount is the moved value, not the balance delta — the
    /// SDK's `poolCrossingValue` must ride into the app model unchanged.
    @Test func poolCrossingValueFlowsThroughFromOverview() {
        let state = TransactionState(
            transaction: overview(
                sentNoteCount: 1,
                receivedNoteCount: 1,
                value: Zatoshi(-10_000),
                poolCrossingValue: Zatoshi(1_000_000_000),
                zip318Kind: .transfer
            )
        )
        #expect(state.poolCrossingValue == Zatoshi(1_000_000_000))
    }

    @Test func isMigrationTransactionCoversExactlyPreparationAndTransfer() {
        var state = TransactionState(fee: Zatoshi(10), id: "m", status: .paid, zecAmount: Zatoshi(-10))
        state.zip318Kind = .preparation
        #expect(state.isMigrationTransaction)
        state.zip318Kind = .transfer
        #expect(state.isMigrationTransaction)
        state.zip318Kind = .notClassified
        #expect(!state.isMigrationTransaction)
        state.zip318Kind = .nonconforming
        #expect(!state.isMigrationTransaction)
    }

    /// The approved copy matrix: kind × status → row title / detail title. Compared through the
    /// localization accessors so the mapping is pinned independent of translation values.
    @Test func zip318TitlesMatchTheApprovedCopy() {
        var state = TransactionState(fee: Zatoshi(10), id: "m", status: .sending, zecAmount: Zatoshi(-10))
        let matrix: [(ZcashTransaction.Overview.ZIP318Kind, TransactionState.Status, String, String)] = [
            (.transfer, .sending, String(localizable: .transactionMigrating), String(localizable: .transactionMigrating)),
            (.transfer, .paid, String(localizable: .transactionMigrated), String(localizable: .transactionMigrated)),
            (.transfer, .failed, String(localizable: .transactionMigrationFailed), String(localizable: .transactionMigrationFailed)),
            (.preparation, .sending, String(localizable: .transactionSplittingBalance), String(localizable: .transactionSplittingBalance)),
            (.preparation, .paid, String(localizable: .transactionBalanceSplit), String(localizable: .transactionBalanceSplit)),
            (.preparation, .failed, String(localizable: .transactionSplitFailed), String(localizable: .transactionBalanceSplitFailed))
        ]
        for (kind, status, rowTitle, detailTitle) in matrix {
            state.zip318Kind = kind
            state.status = status
            #expect(state.title() == rowTitle, "row title for \(kind)/\(status)")
            #expect(state.title(true) == detailTitle, "detail title for \(kind)/\(status)")
        }
    }

    /// Unclassified and non-conforming transactions keep today's titles — no label may leak.
    @Test func nonMigrationTitlesAreUntouched() {
        var state = TransactionState(fee: Zatoshi(10), id: "m", status: .paid, zecAmount: Zatoshi(-10))
        state.zip318Kind = .notClassified
        #expect(state.title() == String(localizable: .transactionSent))
        state.zip318Kind = .nonconforming
        state.status = .sending
        #expect(state.title() == String(localizable: .transactionSending))
    }

    /// Transfers present the pool-crossing value; preparations never cross pools so they fall
    /// back to `totalReceived` (the re-noted value — the same figure the B2 pending sum uses).
    @Test func displayedAmountUsesPoolCrossingValueForTransfers() {
        var state = TransactionState(fee: Zatoshi(10), id: "t", status: .paid, zecAmount: Zatoshi(-10))
        state.zip318Kind = .transfer
        state.poolCrossingValue = Zatoshi(1_000_000_000)
        state.totalReceived = Zatoshi(999_990_000)
        #expect(state.displayedAmount == Zatoshi(1_000_000_000).atLeastThreeDecimalsZashiFormatted())
    }

    @Test func displayedAmountFallsBackToTotalReceivedForPreparations() {
        var state = TransactionState(fee: Zatoshi(10), id: "p", status: .sending, zecAmount: Zatoshi(-10))
        state.zip318Kind = .preparation
        state.poolCrossingValue = nil
        state.totalReceived = Zatoshi(245_800_000)
        #expect(state.displayedAmount == Zatoshi(245_800_000).atLeastThreeDecimalsZashiFormatted())
    }

    /// Regular transactions keep `netValue` exactly — including the shielding special case.
    @Test func displayedAmountOfARegularTransactionIsNetValue() {
        var state = TransactionState(fee: Zatoshi(10), id: "r", status: .paid, zecAmount: Zatoshi(123_456))
        state.zip318Kind = .notClassified
        #expect(state.displayedAmount == state.netValue)
        var shielding = TransactionState(fee: Zatoshi(10), id: "s", status: .shielded, zecAmount: Zatoshi(0))
        shielding.isShieldingTransaction = true
        shielding.totalSpent = Zatoshi(777_000)
        #expect(shielding.displayedAmount == shielding.netValue)
    }

    /// Per design, a failed migration row keeps the primary amount color — never the error red
    /// a regular failed send shows.
    @Test func failedMigrationRowsKeepPrimaryAmountColor() {
        var state = TransactionState(fee: Zatoshi(10), id: "f", status: .failed, zecAmount: Zatoshi(-10))
        state.zip318Kind = .transfer
        #expect(state.titleColor(.light) == Design.Text.primary.color(.light))
        #expect(state.titleColor(.dark) == Design.Text.primary.color(.dark))
    }

    /// Both migration kinds render the coins-swap glyph in every state; color carries the state.
    @Test func migrationRowsUseTheCoinsSwapGlyph() {
        var state = TransactionState(fee: Zatoshi(10), id: "i", status: .sending, zecAmount: Zatoshi(-10))
        state.zip318Kind = .preparation
        #expect(state.transationIcon == Asset.Assets.Icons.coinsSwap.image)
        state.zip318Kind = .transfer
        state.status = .failed
        #expect(state.transationIcon == Asset.Assets.Icons.coinsSwap.image)
    }

    /// A stored-but-unmined transaction has no block time; while it is live the subtitle reads
    /// "Today", and an expired (failed) one keeps the empty subtitle.
    @Test func unminedPendingRowsReadTodayAndFailedOnesStayBlank() {
        var state = TransactionState(fee: Zatoshi(10), id: "d", status: .sending, zecAmount: Zatoshi(-10))
        #expect(state.timestamp == nil)
        #expect(state.daysAgo == String(localizable: .filterToday))
        state.status = .failed
        #expect(state.daysAgo.isEmpty)
    }
}
