//
//  CurrencyConversionTests.swift
//  secantTests
//
//  Created by Cosmos on 18.05.2026.
//

import XCTest
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet


class CurrencyConversionTests: XCTestCase {

    func testInitRoundsRatioToSixDecimals() {
        let conversion = CurrencyConversion(.usd, ratio: 1.123456789, timestamp: 0)

        XCTAssertEqual(
            conversion.ratio,
            1.123456,
            accuracy: 0.0000001,
            "CurrencyConversion tests: `testInitRoundsRatioToSixDecimals` ratio is expected to be 1.123456 but it is \(conversion.ratio)"
        )
    }

    func testInitPreservesExactRatioWithinPrecision() {
        let conversion = CurrencyConversion(.usd, ratio: 50.5, timestamp: 0)

        XCTAssertEqual(
            conversion.ratio,
            50.5,
            accuracy: 0.0000001,
            "CurrencyConversion tests: `testInitPreservesExactRatioWithinPrecision` ratio is expected to be 50.5 but it is \(conversion.ratio)"
        )
    }

    func testInitPreservesTimestamp() {
        let timestamp: TimeInterval = 1700000000
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: timestamp)

        XCTAssertEqual(
            conversion.timestamp,
            timestamp,
            "CurrencyConversion tests: `testInitPreservesTimestamp` timestamp is expected to be \(timestamp) but it is \(conversion.timestamp)"
        )
    }

    func testInitPreservesISO4217() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)

        XCTAssertEqual(
            conversion.iso4217,
            .usd,
            "CurrencyConversion tests: `testInitPreservesISO4217` iso4217 is expected to be .usd but it is \(conversion.iso4217)"
        )
    }

    func testConvertZatoshiToDoubleOneZecAtRatio30() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)
        let oneZEC = Zatoshi(100_000_000)

        let result: Double = conversion.convert(oneZEC)

        XCTAssertEqual(
            result,
            30.0,
            accuracy: 0.01,
            "CurrencyConversion tests: `testConvertZatoshiToDoubleOneZecAtRatio30` result is expected to be 30.0 but it is \(result)"
        )
    }

    func testConvertZatoshiToDoubleHalfZecAtRatio100() {
        let conversion = CurrencyConversion(.usd, ratio: 100.0, timestamp: 0)
        let halfZEC = Zatoshi(50_000_000)

        let result: Double = conversion.convert(halfZEC)

        XCTAssertEqual(
            result,
            50.0,
            accuracy: 0.01,
            "CurrencyConversion tests: `testConvertZatoshiToDoubleHalfZecAtRatio100` result is expected to be 50.0 but it is \(result)"
        )
    }

    func testConvertZatoshiToDoubleZeroZatoshi() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)
        let zero = Zatoshi(0)

        let result: Double = conversion.convert(zero)

        XCTAssertEqual(
            result,
            0.0,
            accuracy: 0.0001,
            "CurrencyConversion tests: `testConvertZatoshiToDoubleZeroZatoshi` result is expected to be 0.0 but it is \(result)"
        )
    }

    func testConvertZatoshiToDoubleSmallAmount() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)
        let oneZatoshi = Zatoshi(1)

        let result: Double = conversion.convert(oneZatoshi)

        XCTAssertEqual(
            result,
            0.0000003,
            accuracy: 0.00000001,
            "CurrencyConversion tests: `testConvertZatoshiToDoubleSmallAmount` result is expected to be 0.0000003 but it is \(result)"
        )
    }

    func testConvertZatoshiToDoubleLargeAmount() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)
        let tenThousandZEC = Zatoshi(10_000 * 100_000_000)

        let result: Double = conversion.convert(tenThousandZEC)

        XCTAssertEqual(
            result,
            300_000.0,
            accuracy: 0.01,
            "CurrencyConversion tests: `testConvertZatoshiToDoubleLargeAmount` result is expected to be 300000.0 but it is \(result)"
        )
    }

    func testConvertZatoshiToStringFormatsAsCurrency() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)
        let oneZEC = Zatoshi(100_000_000)

        let result: String = conversion.convert(oneZEC)

        XCTAssertFalse(
            result.isEmpty,
            "CurrencyConversion tests: `testConvertZatoshiToStringFormatsAsCurrency` is expected to produce a non-empty string"
        )
        XCTAssertTrue(
            result.contains("30") || result.contains("30.00"),
            "CurrencyConversion tests: `testConvertZatoshiToStringFormatsAsCurrency` is expected to contain the converted amount but it is \(result)"
        )
    }

    func testConvertZatoshiToStringZeroAmount() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)
        let zero = Zatoshi(0)

        let result: String = conversion.convert(zero)

        XCTAssertFalse(
            result.isEmpty,
            "CurrencyConversion tests: `testConvertZatoshiToStringZeroAmount` is expected to produce a non-empty string"
        )
    }

    func testConvertCurrencyToZatoshiThirtyDollarsAtRatio30() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)

        let result = conversion.convert(30.0)

        XCTAssertEqual(
            result.amount,
            100_000_000,
            "CurrencyConversion tests: `testConvertCurrencyToZatoshiThirtyDollarsAtRatio30` amount is expected to be 100000000 but it is \(result.amount)"
        )
    }

    func testConvertCurrencyToZatoshiFifteenDollarsAtRatio30() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)

        let result = conversion.convert(15.0)

        XCTAssertEqual(
            result.amount,
            50_000_000,
            "CurrencyConversion tests: `testConvertCurrencyToZatoshiFifteenDollarsAtRatio30` amount is expected to be 50000000 but it is \(result.amount)"
        )
    }

    func testConvertCurrencyToZatoshiZeroDollars() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)

        let result = conversion.convert(0.0)

        XCTAssertEqual(
            result.amount,
            0,
            "CurrencyConversion tests: `testConvertCurrencyToZatoshiZeroDollars` amount is expected to be 0 but it is \(result.amount)"
        )
    }

    func testConvertCurrencyToZatoshiOneCent() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)

        let result = conversion.convert(0.01)

        XCTAssertEqual(
            result.amount,
            33333,
            "CurrencyConversion tests: `testConvertCurrencyToZatoshiOneCent` amount is expected to be 33333 but it is \(result.amount)"
        )
    }

    func testConvertCurrencyToZatoshiLargeDollarAmount() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)

        let result = conversion.convert(3000.0)

        XCTAssertEqual(
            result.amount,
            10_000_000_000,
            "CurrencyConversion tests: `testConvertCurrencyToZatoshiLargeDollarAmount` amount is expected to be 10000000000 but it is \(result.amount)"
        )
    }

    func testRoundTripZatoshiToFiatAndBack() {
        let conversion = CurrencyConversion(.usd, ratio: 45.67, timestamp: 0)
        let original = Zatoshi(123_456_789)

        let fiatValue: Double = conversion.convert(original)
        let backToZatoshi = conversion.convert(fiatValue)

        let diff = abs(original.amount - backToZatoshi.amount)
        XCTAssertLessThan(
            diff,
            100,
            "CurrencyConversion tests: `testRoundTripZatoshiToFiatAndBack` round-trip is expected to be within 100 zatoshi but diff is \(diff)"
        )
    }

    func testConvertVeryHighRatio() {
        let conversion = CurrencyConversion(.usd, ratio: 999999.0, timestamp: 0)
        let oneZEC = Zatoshi(100_000_000)

        let result: Double = conversion.convert(oneZEC)

        XCTAssertEqual(
            result,
            999999.0,
            accuracy: 1.0,
            "CurrencyConversion tests: `testConvertVeryHighRatio` result is expected to be 999999.0 but it is \(result)"
        )
    }

    func testConvertVeryLowRatio() {
        let conversion = CurrencyConversion(.usd, ratio: 0.001, timestamp: 0)
        let oneZEC = Zatoshi(100_000_000)

        let result: Double = conversion.convert(oneZEC)

        XCTAssertEqual(
            result,
            0.001,
            accuracy: 0.0001,
            "CurrencyConversion tests: `testConvertVeryLowRatio` result is expected to be 0.001 but it is \(result)"
        )
    }

    func testConvertNegativeZatoshi() {
        let conversion = CurrencyConversion(.usd, ratio: 30.0, timestamp: 0)
        let negative = Zatoshi(-100_000_000)

        let result: Double = conversion.convert(negative)

        XCTAssertEqual(
            result,
            -30.0,
            accuracy: 0.01,
            "CurrencyConversion tests: `testConvertNegativeZatoshi` result is expected to be -30.0 but it is \(result)"
        )
    }

    func testCurrencyISO4217UsdCode() {
        XCTAssertEqual(
            CurrencyISO4217.usd.code,
            "USD",
            "CurrencyConversion tests: `testCurrencyISO4217UsdCode` code is expected to be USD but it is \(CurrencyISO4217.usd.code)"
        )
    }

    func testCurrencyISO4217UsdSymbol() {
        XCTAssertEqual(
            CurrencyISO4217.usd.symbol,
            "$",
            "CurrencyConversion tests: `testCurrencyISO4217UsdSymbol` symbol is expected to be $ but it is \(CurrencyISO4217.usd.symbol)"
        )
    }

    func testCurrencyISO4217AllCases() {
        XCTAssertEqual(
            CurrencyISO4217.allCases.count,
            1,
            "CurrencyConversion tests: `testCurrencyISO4217AllCases` count is expected to be 1 but it is \(CurrencyISO4217.allCases.count)"
        )
        XCTAssertTrue(
            CurrencyISO4217.allCases.contains(.usd),
            "CurrencyConversion tests: `testCurrencyISO4217AllCases` is expected to contain .usd"
        )
    }

    func testEquatableSameValuesAreEqual() {
        let a = CurrencyConversion(.usd, ratio: 30.0, timestamp: 1000)
        let b = CurrencyConversion(.usd, ratio: 30.0, timestamp: 1000)

        XCTAssertEqual(
            a,
            b,
            "CurrencyConversion tests: `testEquatableSameValuesAreEqual` conversions with same values are expected to be equal"
        )
    }

    func testEquatableDifferentRatioAreNotEqual() {
        let a = CurrencyConversion(.usd, ratio: 30.0, timestamp: 1000)
        let b = CurrencyConversion(.usd, ratio: 31.0, timestamp: 1000)

        XCTAssertNotEqual(
            a,
            b,
            "CurrencyConversion tests: `testEquatableDifferentRatioAreNotEqual` conversions with different ratios are expected to not be equal"
        )
    }

    func testEquatableDifferentTimestampAreNotEqual() {
        let a = CurrencyConversion(.usd, ratio: 30.0, timestamp: 1000)
        let b = CurrencyConversion(.usd, ratio: 30.0, timestamp: 2000)

        XCTAssertNotEqual(
            a,
            b,
            "CurrencyConversion tests: `testEquatableDifferentTimestampAreNotEqual` conversions with different timestamps are expected to not be equal"
        )
    }
}
