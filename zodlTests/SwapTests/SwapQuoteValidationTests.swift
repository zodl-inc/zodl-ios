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
}
