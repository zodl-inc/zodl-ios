//
//  SwapFeeDisplayTests.swift
//  zodlTests
//
//  MOB-1351 — the swap / CrossPay confirmation total must reflect the real affiliate fee
//  (zashiFeeBps = 67 bps = 0.67%), not a hardcoded 0.5%. Single source of truth is
//  SwapAndPayClient.Constants.zashiFeeCoefficient, derived from zashiFeeBps.
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct SwapFeeDisplayTests {
    private func makeQuote(amountIn: Decimal) -> SwapQuote {
        SwapQuote(
            depositAddress: "deposit",
            amountIn: amountIn,
            amountInUsd: "10",
            minAmountIn: Decimal(0),
            amountOut: Decimal(0),
            amountOutUsd: "0",
            timeEstimate: 0,
            recipient: "recipient",
            originAssetId: "origin",
            destinationAssetId: "dest"
        )
    }

    /// The confirmation total fee must use the real 0.67% affiliate fee, not the old hardcoded 0.5%.
    @Test func totalFeesUsesZashiFeeBpsNotHardcodedHalfPercent() {
        var state = SwapAndPayCoordFlow.State()
        state.swapAndPayState.quote = makeQuote(amountIn: Decimal(100_000_000)) // 1 ZEC, in zatoshi
        state.swapAndPayState.proposal = .testOnlyFakeProposal(totalFee: 10_000)

        // The affiliate-fee portion of the total must be 0.67% of amountIn (670_000 zatoshi for 1 ZEC),
        // not the old hardcoded 0.5% (500_000) — independent of whatever the network fee is.
        let networkFee = state.swapAndPayState.proposal?.totalFeeRequired().amount ?? 0
        #expect(state.swapAndPayState.totalFees == networkFee + 670_000)
        #expect(state.swapAndPayState.totalFees != networkFee + 500_000)
    }

    /// Locks the single source of truth: the coefficient is derived from zashiFeeBps, so a future bps
    /// change flows through everywhere and the `0.005` literal can't creep back.
    @Test func zashiFeeCoefficientDerivesFromBps() {
        #expect(
            SwapAndPayClient.Constants.zashiFeeCoefficient
                == Decimal(SwapAndPayClient.Constants.zashiFeeBps) / Decimal(10_000)
        )
        #expect(SwapAndPayClient.Constants.zashiFeeCoefficient == Decimal(67) / Decimal(10_000))
    }

    /// The post-swap transaction-detail screen must show the same 0.67% affiliate fee as the
    /// confirmation screen, not the old hardcoded 0.5%. Guards `TransactionDetails.State.totalSwapToZecFee`
    /// against the same `0.005` literal the confirmation sites were fixed for.
    @Test func transactionDetailSwapToZecFeeUsesZashiFeeBpsNotHardcodedHalfPercent() {
        let amountIn = Decimal(10_000)
        var state = TransactionDetails.State(transaction: TransactionState.placeholder())
        state.swapDetails = SwapDetails(
            amountInFormatted: amountIn,
            amountInUsd: nil,
            amountOutFormatted: nil,
            amountOutUsd: nil,
            fromAsset: "nep141:btc.omft.near",
            toAsset: "nep141:zec.omft.near",
            isSwap: true,
            slippage: nil,
            status: .success,
            refundedAmountFormatted: nil,
            swapRecipient: nil,
            addressToCheckShield: "",
            whenInitiated: "",
            deadline: "",
            depositedAmountFormatted: nil
        )

        // Build the expected strings with the store's own formatter so the assertion is locale-independent.
        let correctFee = amountIn * SwapAndPayClient.Constants.zashiFeeCoefficient
        let correctDisplay = state.conversionFormatter.string(from: NSDecimalNumber(decimal: correctFee)) ?? ""
        let oldHalfPercentFee = amountIn * (Decimal(5) / Decimal(1_000))
        let oldHalfPercentDisplay = state.conversionFormatter.string(from: NSDecimalNumber(decimal: oldHalfPercentFee)) ?? ""

        #expect(state.totalSwapToZecFee == correctDisplay)
        #expect(state.totalSwapToZecFee != oldHalfPercentDisplay)
    }
}
