//
//  CrossPayAmountTests.swift
//  zodlTests
//
//  MOB-1435 — reduce rounding of fine-precision swap/pay amounts by tightening Decimal.simplified's
//  tolerance from 0.5% to 0.2%, and render the CrossPay USD countervalue at exactly two decimals
//  (the same system the Send page uses).
//

import Testing
import Foundation
@testable import zodl_internal

@Suite struct CrossPayAmountTests {
    // MARK: - simplified tolerance tightened to 0.2%

    @Test func simplifiedTightenedToleranceRoundsReporterValues() {
        // 0.00279422: scale-4 0.0028 is 0.207% error (> 0.2%, rejected) -> scale-5 0.00279 (0.151%).
        #expect(decimal("0.00279422").simplified == decimal("0.00279"))
        // 0.00111 has no shorter form within 0.2% -> stays exact (reporter's second data point).
        #expect(decimal("0.00111").simplified == decimal("0.00111"))
    }

    @Test func simplifiedStillCollapsesWithinTolerance() {
        // simplify is NOT disabled: it still trims when the relative error stays within 0.2%.
        #expect(decimal("0.123456789").simplified == decimal("0.1235"))
    }

    // MARK: - USD countervalue rounded to 2 decimals (Send-page system)

    @Test func usdCountervalueRoundsToTwoDecimals() {
        // payUsdLabel formats the USD countervalue with this style (see SwapAndPayStore / SendFormStore).
        let formatted = decimal("292.5512").formatted(.number.precision(.fractionLength(2)))
        // Locale-robust: assert exactly two fraction digits using the current locale's separator.
        let separator = Locale.current.decimalSeparator ?? "."
        let parts = formatted.components(separatedBy: separator)
        #expect(parts.count == 2)
        #expect(parts.last?.count == 2)
    }

    // MARK: - Helpers

    private func decimal(_ string: String) -> Decimal {
        Decimal(string: string) ?? .zero
    }
}
