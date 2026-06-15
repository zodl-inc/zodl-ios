//
//  Near1ClickQuoteMapperTests.swift
//  Zashi
//

import Foundation
import Testing
@testable import zodl_internal

@Suite struct Near1ClickQuoteMapperTests {
    private let zecAsset = SwapAsset(provider: "near", chain: "zec", token: "ZEC", assetId: "zec.id", usdPrice: Decimal(30), decimals: 8)
    private let btcAsset = SwapAsset(provider: "near", chain: "btc", token: "BTC", assetId: "btc.id", usdPrice: Decimal(60_000), decimals: 8)

    private func request(amount: String = "100000000", recipient: String = "recipient", refundTo: String = "refund") -> SwapQuoteRequest {
        SwapQuoteRequest(
            dry: false, swapType: Near1Click.Constants.exactInput, slippageTolerance: 100,
            originAsset: "zec.id", depositType: Near1Click.Constants.originChain, destinationAsset: "btc.id",
            amount: amount, refundTo: refundTo, refundType: Near1Click.Constants.originChain,
            recipient: recipient, recipientType: Near1Click.Constants.destinationChain,
            deadline: "", referral: Near1Click.Constants.referral, quoteWaitingTimeMs: 3000, appFees: nil
        )
    }

    private func json(
        depositAddress: String = "deposit", originAsset: String = "zec.id", destinationAsset: String = "btc.id",
        swapType: String = Near1Click.Constants.exactInput, slippage: Int = 100,
        recipient: String = "recipient", refundTo: String = "refund",
        amountIn: String = "100000000", amountInFormatted: String = "1", minAmountIn: String = "100000000",
        amountOut: String = "200000", amountOutFormatted: String = "0.002", minAmountOut: String = "198000",
        includeMinAmountOut: Bool = true
    ) -> [String: Any] {
        var quote: [String: Any] = [
            "depositAddress": depositAddress, "amountIn": amountIn, "amountInUsd": "10",
            "amountInFormatted": amountInFormatted, "minAmountIn": minAmountIn,
            "amountOut": amountOut, "amountOutUsd": "10", "amountOutFormatted": amountOutFormatted,
            "timeEstimate": 60
        ]
        if includeMinAmountOut {
            quote["minAmountOut"] = minAmountOut
        }
        return [
            "quote": quote,
            "quoteRequest": [
                "originAsset": originAsset, "destinationAsset": destinationAsset, "swapType": swapType,
                "slippageTolerance": slippage, "recipient": recipient, "refundTo": refundTo
            ]
        ]
    }

    @Test func acceptsValidQuote() throws {
        let quote = try Near1Click.makeValidatedQuote(jsonObject: json(), request: request(), zecAsset: zecAsset, toAsset: btcAsset, isSwapToZec: false)
        #expect(quote.depositAddress == "deposit")
        #expect(quote.amountIn == Decimal(100_000_000))
        #expect(quote.recipient == "recipient")
        #expect(quote.originAssetId == "zec.id")
        #expect(quote.destinationAssetId == "btc.id")
    }

    @Test func rejectsInflatedAmountIn() {
        #expect(throws: SwapQuoteValidationError.requestedAmountMismatch) {
            _ = try Near1Click.makeValidatedQuote(
                jsonObject: self.json(amountIn: "200000000", amountInFormatted: "2", minAmountIn: "200000000"),
                request: self.request(), zecAsset: self.zecAsset, toAsset: self.btcAsset, isSwapToZec: false
            )
        }
    }

    @Test func rejectsRecipientSubstitution() {
        #expect(throws: SwapQuoteValidationError.recipientMismatch) {
            _ = try Near1Click.makeValidatedQuote(
                jsonObject: self.json(recipient: "attacker"),
                request: self.request(), zecAsset: self.zecAsset, toAsset: self.btcAsset, isSwapToZec: false
            )
        }
    }

    @Test func rejectsOriginAssetSubstitution() {
        #expect(throws: SwapQuoteValidationError.assetMismatch(field: "originAsset")) {
            _ = try Near1Click.makeValidatedQuote(
                jsonObject: self.json(originAsset: "zec.tampered"),
                request: self.request(), zecAsset: self.zecAsset, toAsset: self.btcAsset, isSwapToZec: false
            )
        }
    }

    @Test func rejectsMissingMinAmountOut() {
        #expect(throws: (any Error).self) {
            _ = try Near1Click.makeValidatedQuote(
                jsonObject: self.json(includeMinAmountOut: false),
                request: self.request(), zecAsset: self.zecAsset, toAsset: self.btcAsset, isSwapToZec: false
            )
        }
    }

    @Test func depositAddressSubstitutionAloneIsNotCaught() throws {
        // Documented residual: binding cannot detect a swapped deposit address (server-generated, unverifiable).
        // Only transport security (user-opt-in Tor) closes this; the quote still builds with the attacker address.
        let quote = try Near1Click.makeValidatedQuote(
            jsonObject: json(depositAddress: "attacker-deposit"),
            request: request(), zecAsset: zecAsset, toAsset: btcAsset, isSwapToZec: false
        )
        #expect(quote.depositAddress == "attacker-deposit")
    }
}
