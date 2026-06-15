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
}
