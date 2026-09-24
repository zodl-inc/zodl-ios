//
//  CurrencyAmountFormattingTests.swift
//  zodlTests
//

import Foundation
import Testing
@testable import zodl_internal

@Suite
struct CurrencyAmountFormattingTests {
    private let enUS = Locale(identifier: "en_US")
    private let csCZ = Locale(identifier: "cs_CZ")

    @Test
    func threeDecimalCurrencyPreservesItsSmallestUnit() throws {
        let kwd = try #require(CurrencyISO4217(rawValue: "KWD"))

        #expect(kwd.formatNumericAmount(12.345, locale: enUS) == "12.345")
        #expect(kwd.formatNumericAmount(0.004, locale: enUS) == "0.004")
    }

    @Test
    func twoDecimalCurrenciesRoundToTwoPlaces() throws {
        let czk = try #require(CurrencyISO4217(rawValue: "CZK"))

        #expect(CurrencyISO4217.usd.formatNumericAmount(12.346, locale: enUS) == "12.35")
        #expect(czk.formatNumericAmount(12.346, locale: enUS) == "12.35")
    }

    @Test
    func zeroDecimalCurrenciesRoundToWholeUnits() throws {
        let vnd = try #require(CurrencyISO4217(rawValue: "VND"))

        #expect(vnd.formatNumericAmount(12.6, locale: enUS) == "13")
        #expect(CurrencyISO4217.jpy.formatNumericAmount(12.6, locale: enUS) == "13")
        #expect(CurrencyISO4217.krw.formatNumericAmount(12.6, locale: enUS) == "13")
    }

    @Test
    func fourDecimalCurrencyUsesPlatformPrecision() throws {
        let clf = try #require(CurrencyISO4217(rawValue: "CLF"))

        #expect(clf.formatNumericAmount(12.3456, locale: enUS) == "12.3456")
    }

    @Test
    func explicitLocaleControlsTheDecimalSeparator() throws {
        let kwd = try #require(CurrencyISO4217(rawValue: "KWD"))
        let czk = try #require(CurrencyISO4217(rawValue: "CZK"))

        #expect(kwd.formatNumericAmount(12.345, locale: csCZ) == "12,345")
        #expect(czk.formatNumericAmount(12.346, locale: csCZ) == "12,35")
    }
}
