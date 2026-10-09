//
//  ZatoshiStringRepresentationCommaTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 2024-02-12.
//

import Testing
import Foundation
@preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite struct ZatoshiStringRepresentationCommaTests {
    // Only value types (Int64 / simple app enums / String), so it is safe to treat as Sendable.
    struct Sample: @unchecked Sendable {
        let zatoshi: Int64
        let prefix: ZatoshiStringRepresentation.PrefixSymbol
        let format: ZatoshiStringRepresentation.Format
        let most: String
        let least: String
    }

    @Test(arguments: csCZZatoshiSamples)
    func significantDigits(_ sample: Sample) {
        let repr = FormatterTestGate.shared.withLockUnchecked {
            NumberFormatter.zashiBalanceFormatter.locale = Locale(identifier: "cs_CZ")
            NumberFormatter.zcashNumberFormatter8FractionDigits.locale = Locale(identifier: "cs_CZ")
            return ZatoshiStringRepresentation(Zatoshi(sample.zatoshi), prefixSymbol: sample.prefix, format: sample.format)
        }

        #expect(repr.mostSignificantDigits == sample.most)
        #expect(repr.leastSignificantDigits == sample.least)
    }

    @Test func feeFormat() {
        let repr = FormatterTestGate.shared.withLockUnchecked { () -> ZatoshiStringRepresentation in
            NumberFormatter.zashiBalanceFormatter.locale = Locale(identifier: "cs_CZ")
            NumberFormatter.zcashNumberFormatter8FractionDigits.locale = Locale(identifier: "cs_CZ")
            return ZatoshiStringRepresentation(Zatoshi(0))
        }

        #expect(repr.feeFormat == "Typical Fee < 0,001")
    }
}

// cs_CZ locale: comma decimal separator. One row per original `testPrefix*` method.
private let csCZZatoshiSamples: [ZatoshiStringRepresentationCommaTests.Sample] = [
    // Prefix None — Abbreviated
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 0, prefix: .none, format: .abbreviated, most: "0,000", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 99_000, prefix: .none, format: .abbreviated, most: "0,000...", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 100_000, prefix: .none, format: .abbreviated, most: "0,001", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 25_793_456, prefix: .none, format: .abbreviated, most: "0,258", least: ""),
    // Prefix None — Expanded
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 0, prefix: .none, format: .expanded, most: "0,000", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 99_000, prefix: .none, format: .expanded, most: "0,000", least: "99"),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 100_000, prefix: .none, format: .expanded, most: "0,001", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 25_793_456, prefix: .none, format: .expanded, most: "0,257", least: "93456"),
    // Prefix Plus — Abbreviated
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 0, prefix: .plus, format: .abbreviated, most: "+0,000", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 99_000, prefix: .plus, format: .abbreviated, most: "+0,000...", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 100_000, prefix: .plus, format: .abbreviated, most: "+0,001", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 25_793_456, prefix: .plus, format: .abbreviated, most: "+0,258", least: ""),
    // Prefix Plus — Expanded
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 0, prefix: .plus, format: .expanded, most: "+0,000", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 99_000, prefix: .plus, format: .expanded, most: "+0,000", least: "99"),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 100_000, prefix: .plus, format: .expanded, most: "+0,001", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 25_793_456, prefix: .plus, format: .expanded, most: "+0,257", least: "93456"),
    // Prefix Minus — Abbreviated
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 0, prefix: .minus, format: .abbreviated, most: "-0,000", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 99_000, prefix: .minus, format: .abbreviated, most: "-0,000...", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 100_000, prefix: .minus, format: .abbreviated, most: "-0,001", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 25_793_456, prefix: .minus, format: .abbreviated, most: "-0,258", least: ""),
    // Prefix Minus — Expanded
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 0, prefix: .minus, format: .expanded, most: "-0,000", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 99_000, prefix: .minus, format: .expanded, most: "-0,000", least: "99"),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 100_000, prefix: .minus, format: .expanded, most: "-0,001", least: ""),
    ZatoshiStringRepresentationCommaTests.Sample(zatoshi: 25_793_456, prefix: .minus, format: .expanded, most: "-0,257", least: "93456")
]
