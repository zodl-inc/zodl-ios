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

    @Test func rejectsMissingMinAmountOutAsEndpointError() {
        // A malformed/missing field surfaces as EndpointError (NOT a validation error), so it propagates
        // out of the closure's `catch is SwapQuoteValidationError` and still fails closed downstream.
        #expect(throws: SwapAndPayClient.EndpointError.self) {
            _ = try Near1Click.makeValidatedQuote(
                jsonObject: self.json(includeMinAmountOut: false),
                request: self.request(), zecAsset: self.zecAsset, toAsset: self.btcAsset, isSwapToZec: false
            )
        }
    }

    @Test func acceptsValidSwapToZecQuote() throws {
        // Swap-to-ZEC (token -> ZEC, FLEX_INPUT): user fixes the token input; amountIn is divided by the
        // token's decimals and amountOut by ZEC's decimals when built.
        let swapToZecRequest = SwapQuoteRequest(
            dry: false, swapType: Near1Click.Constants.flexInput, slippageTolerance: 100,
            originAsset: "btc.id", depositType: Near1Click.Constants.originChain, destinationAsset: "zec.id",
            amount: "200000", refundTo: "user-btc-addr", refundType: Near1Click.Constants.originChain,
            recipient: "wallet-ua", recipientType: Near1Click.Constants.destinationChain,
            deadline: "", referral: Near1Click.Constants.referral, quoteWaitingTimeMs: 3000, appFees: nil
        )
        let swapToZecJson: [String: Any] = [
            "quote": [
                "depositAddress": "deposit", "amountIn": "200000", "amountInUsd": "10",
                "amountInFormatted": "0.002", "minAmountIn": "200000",
                "amountOut": "100000000", "amountOutUsd": "10", "amountOutFormatted": "1", "minAmountOut": "99000000",
                "timeEstimate": 60
            ],
            "quoteRequest": [
                "originAsset": "btc.id", "destinationAsset": "zec.id", "swapType": Near1Click.Constants.flexInput,
                "slippageTolerance": 100, "recipient": "wallet-ua", "refundTo": "user-btc-addr"
            ]
        ]
        let quote = try Near1Click.makeValidatedQuote(jsonObject: swapToZecJson, request: swapToZecRequest, zecAsset: zecAsset, toAsset: btcAsset, isSwapToZec: true)
        let expectedAmountIn = try #require(Decimal(string: "0.002", locale: Locale(identifier: "en_US_POSIX")))
        #expect(quote.amountIn == expectedAmountIn)
        #expect(quote.amountOut == Decimal(1))
        #expect(quote.originAssetId == "btc.id")
        #expect(quote.destinationAssetId == "zec.id")
    }

    @Test func rejectsSwapTypeSubstitution() {
        #expect(throws: SwapQuoteValidationError.swapTypeMismatch) {
            _ = try Near1Click.makeValidatedQuote(
                jsonObject: self.json(swapType: Near1Click.Constants.exactOutput),
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

    @Test func acceptsValidCrosspayQuote() throws {
        // Crosspay (ZEC -> token, EXACT_OUTPUT): user fixes the token OUTPUT; the ZEC input floats within the
        // slippage ceiling. amountIn (ZEC) is kept raw for signing; amountOut is divided by the token decimals.
        let crosspayRequest = SwapQuoteRequest(
            dry: false, swapType: Near1Click.Constants.exactOutput, slippageTolerance: 100,
            originAsset: "zec.id", depositType: Near1Click.Constants.originChain, destinationAsset: "btc.id",
            amount: "200000", refundTo: "refund", refundType: Near1Click.Constants.originChain,
            recipient: "recipient", recipientType: Near1Click.Constants.destinationChain,
            deadline: "", referral: Near1Click.Constants.referral, quoteWaitingTimeMs: 3000, appFees: nil
        )
        let crosspayJson: [String: Any] = [
            "quote": [
                "depositAddress": "deposit", "amountIn": "300000000", "amountInUsd": "10",
                "amountInFormatted": "3", "minAmountIn": "303000000",
                "amountOut": "200000", "amountOutUsd": "10", "amountOutFormatted": "0.002", "minAmountOut": "200000",
                "timeEstimate": 60
            ],
            "quoteRequest": [
                "originAsset": "zec.id", "destinationAsset": "btc.id", "swapType": Near1Click.Constants.exactOutput,
                "slippageTolerance": 100, "recipient": "recipient", "refundTo": "refund"
            ]
        ]
        let quote = try Near1Click.makeValidatedQuote(jsonObject: crosspayJson, request: crosspayRequest, zecAsset: zecAsset, toAsset: btcAsset, isSwapToZec: false)
        #expect(quote.amountIn == Decimal(300_000_000))
        let expectedAmountOut = try #require(Decimal(string: "0.002", locale: Locale(identifier: "en_US_POSIX")))
        #expect(quote.amountOut == expectedAmountOut)
        #expect(quote.recipient == "recipient")
    }

    @Test func rejectsCrosspayInputAboveSlippageCeiling() {
        // EXACT_OUTPUT input floats: ceiling = amountIn 300000000 × 1.01 = 303000000. A guaranteed worst-case
        // input above that exceeds the user's slippage tolerance and must fail closed.
        let crosspayRequest = SwapQuoteRequest(
            dry: false, swapType: Near1Click.Constants.exactOutput, slippageTolerance: 100,
            originAsset: "zec.id", depositType: Near1Click.Constants.originChain, destinationAsset: "btc.id",
            amount: "200000", refundTo: "refund", refundType: Near1Click.Constants.originChain,
            recipient: "recipient", recipientType: Near1Click.Constants.destinationChain,
            deadline: "", referral: Near1Click.Constants.referral, quoteWaitingTimeMs: 3000, appFees: nil
        )
        let crosspayJson: [String: Any] = [
            "quote": [
                "depositAddress": "deposit", "amountIn": "300000000", "amountInUsd": "10",
                "amountInFormatted": "3", "minAmountIn": "400000000",
                "amountOut": "200000", "amountOutUsd": "10", "amountOutFormatted": "0.002", "minAmountOut": "200000",
                "timeEstimate": 60
            ],
            "quoteRequest": [
                "originAsset": "zec.id", "destinationAsset": "btc.id", "swapType": Near1Click.Constants.exactOutput,
                "slippageTolerance": 100, "recipient": "recipient", "refundTo": "refund"
            ]
        ]
        #expect(throws: SwapQuoteValidationError.slippageExceeded) {
            _ = try Near1Click.makeValidatedQuote(jsonObject: crosspayJson, request: crosspayRequest, zecAsset: self.zecAsset, toAsset: self.btcAsset, isSwapToZec: false)
        }
    }
}
