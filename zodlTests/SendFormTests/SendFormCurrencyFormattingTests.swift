//
//  SendFormCurrencyFormattingTests.swift
//  zodlTests
//

import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal

@Suite(.serialized)
struct SendFormCurrencyFormattingTests {
    // SendForm.State.amount deliberately returns zero under _XCTIsTesting. These cases verify
    // only that the reducer wires each currency's precision into the resulting zero display;
    // nonzero numeric formatting is covered by CurrencyAmountFormattingTests.
    @MainActor
    @Test
    func guardedZeroValueUsesSelectedCurrencyPrecision() async throws {
        let separator = Locale.current.decimalSeparator ?? "."
        let kwd = try #require(CurrencyISO4217(rawValue: "KWD"))
        let vnd = try #require(CurrencyISO4217(rawValue: "VND"))

        try await assertGuardedZeroFormatting(currency: kwd, expected: "0\(separator)000")
        try await assertGuardedZeroFormatting(currency: CurrencyISO4217.usd, expected: "0\(separator)00")
        try await assertGuardedZeroFormatting(currency: vnd, expected: "0")
    }

    @MainActor
    private func assertGuardedZeroFormatting(
        currency: CurrencyISO4217,
        expected: String
    ) async throws {
        var state = SendForm.State.initial
        state.zecAmountText = "1".redacted
        let previousConversion = state.currencyConversion
        state.$currencyConversion.withLock {
            $0 = CurrencyConversion(currency, ratio: 12.345, timestamp: 0)
        }
        defer {
            state.$currencyConversion.withLock { $0 = previousConversion }
        }

        let store = TestStore(initialState: state) {
            SendForm()
        }

        await store.send(.syncAmounts(true)) {
            $0.currencyText = expected.redacted
        }
        await store.finish()
    }
}
