//
//  SafeNumericConversionsTests.swift
//  Zashi
//

import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite struct SafeNumericConversionsTests {
    @Test func clampedInt64ReturnsValueInRange() {
        #expect(NSDecimalNumber(value: 100).clampedInt64Value == 100)
    }

    @Test func clampedInt64ClampsAboveMax() {
        let huge = NSDecimalNumber(string: "99999999999999999999")
        #expect(huge.clampedInt64Value == Int64.max)
    }

    @Test func clampedInt64ClampsBelowMin() {
        let veryNegative = NSDecimalNumber(string: "-99999999999999999999")
        #expect(veryNegative.clampedInt64Value == Int64.min)
    }

    @Test func clampedInt64TruncatesNonInteger() {
        // Regression: NSDecimalNumber.int64Value returns 0 for any value with a fractional part, so an
        // in-range non-integer (e.g. the slippage buffer in swapSlippageStr) must be truncated, not zeroed.
        #expect(NSDecimalNumber(string: "333333.3333").clampedInt64Value == 333_333)
        #expect(NSDecimalNumber(string: "0.9").clampedInt64Value == 0)
        #expect(NSDecimalNumber(string: "100.5").clampedInt64Value == 100)
    }

    @Test func clampedInt64MapsNaNToZero() {
        // A NaN (e.g. a Decimal division by a server usdPrice of 0) must fall back to 0, not Int64.min.
        #expect(NSDecimalNumber.notANumber.clampedInt64Value == 0)
    }

    @Test func safeZatoshiAcceptsNormalValue() {
        let zatoshi = Zatoshi(safeZatoshiDecimal: Decimal(100_000_000))
        #expect(zatoshi == Zatoshi(100_000_000))
    }

    @Test func safeZatoshiTruncatesFraction() throws {
        let value = try #require(Decimal(string: "100000000.9", locale: Locale(identifier: "en_US_POSIX")))
        #expect(Zatoshi(safeZatoshiDecimal: value) == Zatoshi(100_000_000))
    }

    @Test func safeZatoshiRejectsNegative() {
        #expect(Zatoshi(safeZatoshiDecimal: Decimal(-1)) == nil)
    }

    @Test func safeZatoshiRejectsOverMaxSupply() throws {
        let overMax = try #require(Decimal(string: "99999999999999999999", locale: Locale(identifier: "en_US_POSIX")))
        #expect(Zatoshi(safeZatoshiDecimal: overMax) == nil)
    }
}
