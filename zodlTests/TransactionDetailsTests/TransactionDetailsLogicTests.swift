//
//  TransactionDetailsLogicTests.swift
//  zodlTests
//
//  Extended — transactions. Covers TransactionDetails.State computed props (footer ladder, swap-status
//  mapping, asset lookup, missing funds, fee strings) (Features/TransactionDetails/TransactionDetailsStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZODLSwiftWalletSDK

@Suite(.serialized) struct TransactionDetailsLogicTests {
    @Test func feeStrUsesTransactionFeeOrDefault() {
        #expect(!state(transaction: tx(fee: Zatoshi(100_000))).feeStr.isEmpty)
        #expect(state(transaction: tx(fee: nil)).feeStr == String(localizable: .transactionHistoryDefaultFee))
    }

    @Test func memosReadsSharedTransactionMemos() {
        #expect(state(memos: ["hello", "world"]).memos == ["hello", "world"])
        #expect(state().memos.isEmpty)
    }

    @Test func totalFeesStrFromUmSwapId() {
        #expect(state(umSwapId: umSwap(totalFees: 100_000)).totalFeesStr != nil)
        #expect(state().totalFeesStr == nil)
    }

    @Test func swapStatusNilWithoutDetailsAndMappedWithDetails() {
        #expect(state().swapStatus == nil)
        #expect(state(swap: swap(status: .success)).swapStatus == .success)
        #expect(state(swap: swap(status: .failed)).swapStatus == .failed)
    }

    @Test func footerStateNonSwapShowsAddNote() {
        var s = state(transaction: tx())
        s.isSwap = false
        s.swapDetails = nil
        #expect(s.footerState == .addNote)
    }

    @Test func footerStateUnsuccessfulShowsContactSupport() {
        #expect(state(swap: swap(status: .failed)).footerState == .contactSupport)
        #expect(state(swap: swap(status: .refunded)).footerState == .contactSupport)
        #expect(state(swap: swap(status: .expired)).footerState == .contactSupport)
    }

    @Test func footerStatePendingDepositShowsDepositInfo() {
        var s = state(transaction: tx(), swap: swap(status: .pendingDeposit))
        s.isSwap = true
        #expect(s.footerState == .depositInfo)
    }

    @Test func swapToZecTitleMapsStatus() {
        #expect(state(swap: swap(status: .success)).swapToZecTitle == String(localizable: .swapToZecSwapCompleted))
        #expect(state(swap: swap(status: .refunded)).swapToZecTitle == String(localizable: .swapToZecSwapRefunded))
        #expect(state().swapToZecTitle == nil)
    }

    @Test func swapFromAndToAssetLookupIsCaseInsensitive() {
        let from = SwapAsset(provider: "near", chain: "eth", token: "ETH", assetId: "eth-id", usdPrice: 0, decimals: 18)
        let to = SwapAsset(provider: "near", chain: "zec", token: "ZEC", assetId: "zec-id", usdPrice: 0, decimals: 8)
        let s = state(
            swap: swap(amountOut: Decimal(1), fromAsset: "ETH-ID", toAsset: "ZEC-ID"),
            swapAssets: [from, to]
        )
        #expect(s.swapFromAsset?.assetId == "eth-id")
        #expect(s.swapToAsset?.assetId == "zec-id")
    }

    @Test func missingFundsIsAmountInMinusDeposited() {
        #expect(state(swap: swap(amountIn: Decimal(10), deposited: Decimal(3))).missingFunds != nil)
        #expect(state().missingFunds == nil)
    }

    @Test func totalSwapToZecFeeNilWithoutAmount() {
        // Value not asserted: it currently reflects a hardcoded 0.005 (see plan doc §6.5).
        #expect(state().totalSwapToZecFee == nil)
        #expect(state(swap: swap(amountIn: Decimal(100))).totalSwapToZecFee != nil)
    }

    @Test func swapToZecFeeInProgress() {
        #expect(state(swap: swap(status: .success)).swapToZecFeeInProgress == false)
        #expect(state(swap: swap(status: .pending)).swapToZecFeeInProgress == true)
        #expect(state().swapToZecFeeInProgress == true)
    }

    // MARK: - Helpers

    private func state(
        transaction: TransactionState? = nil,
        swap sd: SwapDetails? = nil,
        swapAssets: [SwapAsset] = [],
        umSwapId: UMSwapId? = nil,
        memos: [String]? = nil
    ) -> TransactionDetails.State {
        var s = TransactionDetails.State(transaction: transaction ?? tx())
        s.swapDetails = sd
        s.isSwap = sd != nil
        s.umSwapId = umSwapId
        s.$swapAssets.withLock { $0 = IdentifiedArrayOf(uniqueElements: swapAssets) }
        if let memos {
            s.$transactionMemos.withLock { $0 = [s.transaction.id: memos] }
        } else {
            s.$transactionMemos.withLock { $0 = [:] }
        }
        return s
    }

    private func swap(
        status: SwapDetails.Status = .pendingDeposit,
        amountIn: Decimal? = nil,
        amountOut: Decimal? = nil,
        deposited: Decimal? = nil,
        fromAsset: String? = nil,
        toAsset: String? = nil
    ) -> SwapDetails {
        SwapDetails(
            amountInFormatted: amountIn,
            amountInUsd: nil,
            amountOutFormatted: amountOut,
            amountOutUsd: nil,
            fromAsset: fromAsset,
            toAsset: toAsset,
            isSwap: true,
            slippage: nil,
            status: status,
            refundedAmountFormatted: nil,
            swapRecipient: nil,
            addressToCheckShield: "addr",
            whenInitiated: "2023-01-01T00:00:00.000Z",
            deadline: "2023-01-01T00:00:00.000Z",
            depositedAmountFormatted: deposited
        )
    }

    private func umSwap(totalFees: Int64) -> UMSwapId {
        UMSwapId(
            depositAddress: "d", provider: "near", totalFees: totalFees, totalUSDFees: "0",
            lastUpdated: 0, fromAsset: "a", toAsset: "b", exactInput: true, status: "SUCCESS", amountOutFormatted: "0"
        )
    }

    private func tx(fee: Zatoshi? = Zatoshi(10_000)) -> TransactionState {
        TransactionState(fee: fee, id: "tx-id", status: .received, zecAmount: Zatoshi(100_000_000))
    }
}
