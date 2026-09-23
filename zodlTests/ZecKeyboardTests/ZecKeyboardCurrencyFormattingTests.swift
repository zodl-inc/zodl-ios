//
//  ZecKeyboardCurrencyFormattingTests.swift
//  zodlTests
//

import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized)
struct ZecKeyboardCurrencyFormattingTests {
    @MainActor
    @Test
    func convertedOutputUsesZeroTwoAndThreeCurrencyDigits() async throws {
        let separator = Locale.current.decimalSeparator ?? "."
        let kwd = try #require(CurrencyISO4217(rawValue: "KWD"))
        let vnd = try #require(CurrencyISO4217(rawValue: "VND"))

        await assertConvertedOutput(
            currency: kwd,
            currencyValue: 12.345,
            expected: "12\(separator)345"
        )
        await assertConvertedOutput(
            currency: CurrencyISO4217.usd,
            currencyValue: 12.346,
            expected: "12\(separator)35"
        )
        await assertConvertedOutput(
            currency: vnd,
            currencyValue: 12.6,
            expected: "13"
        )
    }

    @MainActor
    @Test
    func missingConversionKeepsTwoDecimalFallback() async {
        let separator = Locale.current.decimalSeparator ?? "."

        await assertConvertedOutput(
            currency: nil,
            currencyValue: 12.346,
            expected: "12\(separator)35"
        )
    }

    @MainActor
    private func assertConvertedOutput(
        currency: CurrencyISO4217?,
        currencyValue: Double,
        expected: String
    ) async {
        var state = ZecKeyboard.State()
        state.amount = Zatoshi(100_000_000)
        state.decimalSeparator = Locale.current.decimalSeparator ?? "."
        state.input = "1"
        state.currencyValue = currencyValue
        let previousConversion = state.currencyConversion
        state.$currencyConversion.withLock {
            $0 = currency.map { CurrencyConversion($0, ratio: 1, timestamp: 0) }
        }
        defer {
            state.$currencyConversion.withLock { $0 = previousConversion }
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .currency
        if let currency {
            formatter.currencyCode = currency.code
        }
        formatter.maximumFractionDigits = 8
        state.localeCurrencySymbol = formatter.currencySymbol ?? ""
        state.isCurrencySymbolPrefix = formatter.positivePrefix.contains(formatter.currencySymbol)

        let store = TestStore(initialState: state) {
            ZecKeyboard()
        }

        await store.send(.resolveHumanReadableStrings) {
            $0.humanReadableMainInput = "1"
            $0.humanReadableConvertedInput = expected
        }
        await store.finish()

        #expect(store.state.amount == Zatoshi(100_000_000))
        #expect(store.state.input == "1")
    }
}
