//
//  BalanceFormatterTests.swift
//  zodlTests
//
//  Batch 1 — pure logic. Covers Zatoshi balance formatters (Utils/BalanceFormatter.swift).
//

import Testing
import Foundation
@testable import zodl_internal
@testable @preconcurrency import ZODLSwiftWalletSDK

@Suite struct BalanceFormatterTests {
    // MARK: - roundToAvoidDustSpend (pure integer math, rounds to nearest 5_000)

    @Test func roundToAvoidDustSpendRoundsToNearestFiveThousand() {
        #expect(Zatoshi(0).roundToAvoidDustSpend().amount == 0)
        #expect(Zatoshi(5_000).roundToAvoidDustSpend().amount == 5_000)
        #expect(Zatoshi(7_499).roundToAvoidDustSpend().amount == 5_000)
        #expect(Zatoshi(7_500).roundToAvoidDustSpend().amount == 10_000)
        #expect(Zatoshi(2_500).roundToAvoidDustSpend().amount == 5_000) // 0.5 rounds away from zero
        #expect(Zatoshi(2_499).roundToAvoidDustSpend().amount == 0)
        #expect(Zatoshi(100_000_000).roundToAvoidDustSpend().amount == 100_000_000)
    }

    // MARK: - en_US-pinned formatters (deterministic across locales)

    @Test func decimalZashiUSFormattedUsesThreeFractionDigitsWithGrouping() {
        #expect(Zatoshi(100_000_000).decimalZashiUSFormatted() == "1.000")
        #expect(Zatoshi(123_456_789).decimalZashiUSFormatted() == "1.235") // halfUp at 3 places
        #expect(Zatoshi(1_000_000_000_000).decimalZashiUSFormatted() == "10,000.000")
    }

    @Test func decimalZashiTaxUSFormattedHasNoGrouping() {
        #expect(Zatoshi(100_000_000).decimalZashiTaxUSFormatted() == "1")
        #expect(Zatoshi(1_000_000_000_000).decimalZashiTaxUSFormatted() == "10000")
        #expect(Zatoshi(123_456_789).decimalZashiTaxUSFormatted() == "1.23456789")
    }

    // MARK: - locale-dependent formatters (assert structure only)

    @Test func localeDependentFormattersProduceNonEmptyOutput() {
        let oneZec = Zatoshi(100_000_000)
        #expect(!oneZec.decimalZashiFormatted().isEmpty)
        #expect(!oneZec.decimalZashiFullFormatted().isEmpty)
        #expect(!oneZec.threeDecimalsZashiFormatted().isEmpty)
        #expect(!oneZec.atLeastThreeDecimalsZashiFormatted().isEmpty)
    }
}
