//
//  SwapQuoteValidationTests.swift
//  Zashi
//

import Foundation
import Testing
@testable import zodl_internal

@Suite struct SwapQuoteValidationTests {
    // MARK: requireConsistent — raw base-unit amount must equal formatted × 10^decimals

    @Test func requireConsistentPassesWhenRawMatchesFormatted() throws {
        try SwapQuoteValidator.requireConsistent(name: "amountIn", raw: Decimal(100_000_000), formatted: Decimal(1), decimals: 8)
    }

    @Test func requireConsistentPassesRegardlessOfFormattedScale() throws {
        let formatted = try #require(Decimal(string: "1.00", locale: Locale(identifier: "en_US_POSIX")))
        try SwapQuoteValidator.requireConsistent(name: "amountIn", raw: Decimal(100_000_000), formatted: formatted, decimals: 8)
    }

    @Test func requireConsistentThrowsWhenRawDoesNotMatchFormatted() {
        #expect(throws: SwapQuoteValidationError.amountInconsistency(field: "amountIn")) {
            try SwapQuoteValidator.requireConsistent(name: "amountIn", raw: Decimal(100_000_000), formatted: Decimal(2), decimals: 8)
        }
    }

    @Test func requireConsistentThrowsOnNaNRaw() {
        #expect(throws: SwapQuoteValidationError.amountInconsistency(field: "amountIn")) {
            try SwapQuoteValidator.requireConsistent(name: "amountIn", raw: Decimal.nan, formatted: Decimal(1), decimals: 8)
        }
    }

    @Test func requireConsistentThrowsOnOutOfRangeDecimals() {
        #expect(throws: SwapQuoteValidationError.amountInconsistency(field: "amountIn")) {
            try SwapQuoteValidator.requireConsistent(name: "amountIn", raw: Decimal(100_000_000), formatted: Decimal(1), decimals: 1000)
        }
    }

    @Test func requireConsistentPassesForFractionalFormatted() throws {
        let formatted = try #require(Decimal(string: "0.00000001", locale: Locale(identifier: "en_US_POSIX")))
        try SwapQuoteValidator.requireConsistent(name: "amountIn", raw: Decimal(1), formatted: formatted, decimals: 8)
    }

    @Test func requireConsistentFailsClosedOnOverflowingFormatted() throws {
        // A server-controlled `formatted` can overflow when multiplied by 10^decimals; the default
        // NSDecimalNumber behavior would raise an uncatchable NSDecimalNumberOverflowException (crash).
        // It must instead fail closed.
        let huge = try #require(Decimal(string: "1e120", locale: Locale(identifier: "en_US_POSIX")))
        #expect(throws: SwapQuoteValidationError.amountInconsistency(field: "amountIn")) {
            try SwapQuoteValidator.requireConsistent(name: "amountIn", raw: Decimal(1), formatted: huge, decimals: 8)
        }
    }

    // MARK: requireWithinSlippage — server's worst-case guarantee must respect requested slippage

    @Test func slippageOutputFloatingPassesAtAndAboveFloor() throws {
        // 10% slippage, amountOut=100 -> floor=90. minAmountIn is the fixed side (== amountIn) and ignored.
        try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.exactInput, amountIn: Decimal(1000), amountOut: Decimal(100), minAmountIn: Decimal(1000), minAmountOut: Decimal(90), slippageToleranceBps: 1000)
        try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.flexInput, amountIn: Decimal(1000), amountOut: Decimal(100), minAmountIn: Decimal(1000), minAmountOut: Decimal(95), slippageToleranceBps: 1000)
    }

    @Test func slippageOutputFloatingThrowsBelowFloor() {
        #expect(throws: SwapQuoteValidationError.slippageExceeded) {
            try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.exactInput, amountIn: Decimal(1000), amountOut: Decimal(100), minAmountIn: Decimal(1000), minAmountOut: Decimal(89), slippageToleranceBps: 1000)
        }
    }

    @Test func slippageInputFloatingPassesAtAndBelowCeiling() throws {
        // 10% slippage, amountIn=100 -> ceiling=110. minAmountOut is the fixed side and ignored.
        try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.exactOutput, amountIn: Decimal(100), amountOut: Decimal(1000), minAmountIn: Decimal(110), minAmountOut: Decimal(1000), slippageToleranceBps: 1000)
        try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.exactOutput, amountIn: Decimal(100), amountOut: Decimal(1000), minAmountIn: Decimal(105), minAmountOut: Decimal(1000), slippageToleranceBps: 1000)
    }

    @Test func slippageInputFloatingThrowsAboveCeiling() {
        #expect(throws: SwapQuoteValidationError.slippageExceeded) {
            try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.exactOutput, amountIn: Decimal(100), amountOut: Decimal(1000), minAmountIn: Decimal(111), minAmountOut: Decimal(1000), slippageToleranceBps: 1000)
        }
    }

    @Test func slippageOutputAcceptsServerIntegerTruncatedFloor() throws {
        // Real NEAR 1Click $10 ZEC -> USDC @ 30%: amountOut=9897372 × 0.70 = 6928160.4, server truncates DOWN to 6928160.
        try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.exactInput, amountIn: Decimal(2_245_828), amountOut: Decimal(9_897_372), minAmountIn: Decimal(2_245_828), minAmountOut: Decimal(6_928_160), slippageToleranceBps: 3000)
    }

    @Test func slippageOutputRejectsOneBelowIntegerFloor() {
        #expect(throws: SwapQuoteValidationError.slippageExceeded) {
            try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.exactInput, amountIn: Decimal(2_245_828), amountOut: Decimal(9_897_372), minAmountIn: Decimal(2_245_828), minAmountOut: Decimal(6_928_159), slippageToleranceBps: 3000)
        }
    }

    @Test func slippageInputAcceptsServerIntegerRoundedCeiling() throws {
        // amountIn=9897372 × 1.30 = 12866583.6, server rounds UP to 12866584.
        try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.exactOutput, amountIn: Decimal(9_897_372), amountOut: Decimal(2_245_828), minAmountIn: Decimal(12_866_584), minAmountOut: Decimal(2_245_828), slippageToleranceBps: 3000)
    }

    @Test func slippageInputRejectsOneAboveIntegerCeiling() {
        #expect(throws: SwapQuoteValidationError.slippageExceeded) {
            try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.exactOutput, amountIn: Decimal(9_897_372), amountOut: Decimal(2_245_828), minAmountIn: Decimal(12_866_585), minAmountOut: Decimal(2_245_828), slippageToleranceBps: 3000)
        }
    }

    @Test func slippageFailsClosedOnNaNBound() {
        // Server-controlled min bounds parse to Decimal.nan on garbage; must fail closed, never bypass.
        #expect(throws: SwapQuoteValidationError.slippageExceeded) {
            try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.exactInput, amountIn: Decimal(1000), amountOut: Decimal(100), minAmountIn: Decimal(1000), minAmountOut: Decimal.nan, slippageToleranceBps: 1000)
        }
    }

    @Test func slippageFailsClosedOnNaNAmountInput() {
        #expect(throws: SwapQuoteValidationError.slippageExceeded) {
            try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.exactOutput, amountIn: Decimal.nan, amountOut: Decimal(1000), minAmountIn: Decimal(110), minAmountOut: Decimal(1000), slippageToleranceBps: 1000)
        }
    }

    @Test func slippageFailsClosedOnAbsurdBps() {
        // Without the <= 10_000 bound, bps=10_001 makes (10000 - bps) negative -> floor negative -> any
        // minAmountOut passes (bypass). The bound must make this fail closed.
        #expect(throws: SwapQuoteValidationError.slippageExceeded) {
            try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.exactInput, amountIn: Decimal(1000), amountOut: Decimal(100), minAmountIn: Decimal(1000), minAmountOut: Decimal(0), slippageToleranceBps: 10_001)
        }
    }

    @Test func slippageFailsClosedOnOverflowingOutput() throws {
        // amountOut * (10000 - bps) overflows Decimal; the multiply must not trap, and the NaN result
        // must fail closed (output-floating side).
        let huge = try #require(Decimal(string: "1e125", locale: Locale(identifier: "en_US_POSIX")))
        #expect(throws: SwapQuoteValidationError.slippageExceeded) {
            try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.exactInput, amountIn: Decimal(1000), amountOut: huge, minAmountIn: Decimal(1000), minAmountOut: Decimal(1), slippageToleranceBps: 1000)
        }
    }

    @Test func slippageFailsClosedOnOverflowingInput() throws {
        // amountIn * (10000 + bps) overflows Decimal on the EXACT_OUTPUT ceiling. compare(NaN) is
        // orderedAscending, so without the explicit NaN guard this would bypass — it must fail closed.
        let huge = try #require(Decimal(string: "1e125", locale: Locale(identifier: "en_US_POSIX")))
        #expect(throws: SwapQuoteValidationError.slippageExceeded) {
            try SwapQuoteValidator.requireWithinSlippage(swapType: Near1Click.Constants.exactOutput, amountIn: huge, amountOut: Decimal(1000), minAmountIn: Decimal(1), minAmountOut: Decimal(1000), slippageToleranceBps: 1000)
        }
    }

    // MARK: requireMatchingAssetId

    @Test func requireMatchingAssetIdPassesOnEqual() throws {
        try SwapQuoteValidator.requireMatchingAssetId(field: "originAsset", expected: "nep141:zec.omft.near", actual: "nep141:zec.omft.near")
    }

    @Test func requireMatchingAssetIdThrowsOnDifferent() {
        #expect(throws: SwapQuoteValidationError.assetMismatch(field: "originAsset")) {
            try SwapQuoteValidator.requireMatchingAssetId(field: "originAsset", expected: "a", actual: "b")
        }
    }

    // MARK: requireMatchesRequestedAmount — user-fixed side must equal requested base units

    @Test func requestedAmountExactInputBindsAmountIn() throws {
        try SwapQuoteValidator.requireMatchesRequestedAmount(swapType: Near1Click.Constants.exactInput, requestedAmount: "100000000", rawAmountIn: Decimal(100_000_000), rawAmountOut: Decimal(2_000_000))
    }

    @Test func requestedAmountExactOutputBindsAmountOut() throws {
        try SwapQuoteValidator.requireMatchesRequestedAmount(swapType: Near1Click.Constants.exactOutput, requestedAmount: "2000000", rawAmountIn: Decimal(100_000_000), rawAmountOut: Decimal(2_000_000))
    }

    @Test func requestedAmountFlexInputBindsAmountIn() throws {
        try SwapQuoteValidator.requireMatchesRequestedAmount(swapType: Near1Click.Constants.flexInput, requestedAmount: "2000000", rawAmountIn: Decimal(2_000_000), rawAmountOut: Decimal(100_000_000))
    }

    @Test func requestedAmountThrowsOnInflatedAmountIn() {
        #expect(throws: SwapQuoteValidationError.requestedAmountMismatch) {
            try SwapQuoteValidator.requireMatchesRequestedAmount(swapType: Near1Click.Constants.exactInput, requestedAmount: "100000000", rawAmountIn: Decimal(200_000_000), rawAmountOut: Decimal(2_000_000))
        }
    }

    @Test func requestedAmountFailsClosedOnNaNAmount() {
        #expect(throws: SwapQuoteValidationError.requestedAmountMismatch) {
            try SwapQuoteValidator.requireMatchesRequestedAmount(swapType: Near1Click.Constants.exactInput, requestedAmount: "100000000", rawAmountIn: Decimal.nan, rawAmountOut: Decimal(2_000_000))
        }
    }

    @Test func requestedAmountFailsClosedOnUnparseableRequest() {
        #expect(throws: SwapQuoteValidationError.requestedAmountMismatch) {
            try SwapQuoteValidator.requireMatchesRequestedAmount(swapType: Near1Click.Constants.exactInput, requestedAmount: "not-a-number", rawAmountIn: Decimal(100_000_000), rawAmountOut: Decimal(2_000_000))
        }
    }

    // MARK: validate — full orchestration over a baseline valid EXACT_INPUT quote

    private func baselineRequest(swapType: String = Near1Click.Constants.exactInput, slippage: Int = 100, amount: String = "100000000") -> SwapQuoteRequest {
        SwapQuoteRequest(
            dry: false, swapType: swapType, slippageTolerance: slippage,
            originAsset: "origin.id", depositType: Near1Click.Constants.originChain, destinationAsset: "dest.id",
            amount: amount, refundTo: "refund-addr", refundType: Near1Click.Constants.originChain,
            recipient: "recipient-addr", recipientType: Near1Click.Constants.destinationChain,
            deadline: "", referral: Near1Click.Constants.referral, quoteWaitingTimeMs: 3000, appFees: nil
        )
    }

    private func baselineResponse(
        originAsset: String = "origin.id", destinationAsset: String = "dest.id",
        swapType: String = Near1Click.Constants.exactInput, slippage: Int = 100,
        recipient: String = "recipient-addr", refundTo: String = "refund-addr",
        amountIn: Decimal = Decimal(100_000_000), amountInFormatted: Decimal = Decimal(1),
        minAmountIn: Decimal = Decimal(100_000_000),
        amountOut: Decimal = Decimal(2_000_000), amountOutFormatted: Decimal = Decimal(2),
        minAmountOut: Decimal = Decimal(1_980_000)
    ) -> SwapQuoteResponseFields {
        SwapQuoteResponseFields(
            depositAddress: "deposit-addr", echoedOriginAsset: originAsset, echoedDestinationAsset: destinationAsset,
            echoedSwapType: swapType, echoedSlippageTolerance: slippage, echoedRecipient: recipient, echoedRefundTo: refundTo,
            amountIn: amountIn, amountInFormatted: amountInFormatted, minAmountIn: minAmountIn,
            amountOut: amountOut, amountOutFormatted: amountOutFormatted, minAmountOut: minAmountOut
        )
    }

    private func validateBaseline(request: SwapQuoteRequest? = nil, response: SwapQuoteResponseFields? = nil) throws {
        try SwapQuoteValidator.validate(
            request: request ?? baselineRequest(),
            response: response ?? baselineResponse(),
            originDecimals: 8, destinationDecimals: 6
        )
    }

    @Test func validateAcceptsConsistentQuote() throws {
        try validateBaseline()
    }

    @Test func validateRejectsOriginAssetSubstitution() {
        #expect(throws: SwapQuoteValidationError.assetMismatch(field: "originAsset")) {
            try self.validateBaseline(response: self.baselineResponse(originAsset: "origin.tampered"))
        }
    }

    @Test func validateRejectsDestinationAssetSubstitution() {
        #expect(throws: SwapQuoteValidationError.assetMismatch(field: "destinationAsset")) {
            try self.validateBaseline(response: self.baselineResponse(destinationAsset: "dest.tampered"))
        }
    }

    @Test func validateRejectsSwapTypeSubstitution() {
        #expect(throws: SwapQuoteValidationError.swapTypeMismatch) {
            try self.validateBaseline(response: self.baselineResponse(swapType: Near1Click.Constants.exactOutput))
        }
    }

    @Test func validateRejectsWidenedSlippageTolerance() {
        #expect(throws: SwapQuoteValidationError.slippageToleranceMismatch) {
            try self.validateBaseline(response: self.baselineResponse(slippage: 10_000))
        }
    }

    @Test func validateRejectsRecipientSubstitution() {
        #expect(throws: SwapQuoteValidationError.recipientMismatch) {
            try self.validateBaseline(response: self.baselineResponse(recipient: "attacker-addr"))
        }
    }

    @Test func validateRejectsRefundSubstitution() {
        #expect(throws: SwapQuoteValidationError.refundMismatch) {
            try self.validateBaseline(response: self.baselineResponse(refundTo: "attacker-addr"))
        }
    }

    @Test func validateRejectsNonPositiveAmountIn() {
        #expect(throws: SwapQuoteValidationError.nonPositiveAmount(field: "amountInFormatted")) {
            try self.validateBaseline(response: self.baselineResponse(amountIn: Decimal(0), amountInFormatted: Decimal(0), minAmountIn: Decimal(0)))
        }
    }

    @Test func validateRejectsRawFormattedInconsistency() {
        #expect(throws: SwapQuoteValidationError.amountInconsistency(field: "amountIn")) {
            try self.validateBaseline(response: self.baselineResponse(amountIn: Decimal(999)))
        }
    }

    @Test func validateRejectsInflatedAmountIn() {
        // Consistent at 8 decimals (2 × 1e8 == 200_000_000) but not what the user requested (1 ZEC).
        #expect(throws: SwapQuoteValidationError.requestedAmountMismatch) {
            try self.validateBaseline(response: self.baselineResponse(amountIn: Decimal(200_000_000), amountInFormatted: Decimal(2), minAmountIn: Decimal(200_000_000)))
        }
    }

    @Test func validateRejectsSlippageBelowFloor() {
        #expect(throws: SwapQuoteValidationError.slippageExceeded) {
            try self.validateBaseline(response: self.baselineResponse(minAmountOut: Decimal(1_900_000)))
        }
    }
}
