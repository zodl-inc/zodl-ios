//
//  ZatoshiStringRepresentationTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 17.11.2023.
//

import Testing
import Foundation
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct ZatoshiStringRepresentationTests {
    // Only value types (Int64 / simple app enums / String), so it is safe to treat as Sendable.
    struct Sample: @unchecked Sendable {
        let zatoshi: Int64
        let prefix: ZatoshiStringRepresentation.PrefixSymbol
        let format: ZatoshiStringRepresentation.Format
        let most: String
        let least: String
    }

    @Test(arguments: enUSZatoshiSamples)
    func significantDigits(_ sample: Sample) {
        let repr = FormatterTestGate.shared.withLockUnchecked {
            NumberFormatter.zashiBalanceFormatter.locale = Locale(identifier: "en_US")
            NumberFormatter.zcashNumberFormatter8FractionDigits.locale = Locale(identifier: "en_US")
            return ZatoshiStringRepresentation(Zatoshi(sample.zatoshi), prefixSymbol: sample.prefix, format: sample.format)
        }

        #expect(repr.mostSignificantDigits == sample.most)
        #expect(repr.leastSignificantDigits == sample.least)
    }

    @Test func feeFormat() {
        let repr = FormatterTestGate.shared.withLockUnchecked { () -> ZatoshiStringRepresentation in
            NumberFormatter.zashiBalanceFormatter.locale = Locale(identifier: "en_US")
            NumberFormatter.zcashNumberFormatter8FractionDigits.locale = Locale(identifier: "en_US")
            return ZatoshiStringRepresentation(Zatoshi(0))
        }

        #expect(repr.feeFormat == "Typical Fee < 0.001")
    }
}

// en_US locale: the original 24 `testPrefix*` methods, one row each.
private let enUSZatoshiSamples: [ZatoshiStringRepresentationTests.Sample] = [
    // Prefix None — Abbreviated
    ZatoshiStringRepresentationTests.Sample(zatoshi: 0, prefix: .none, format: .abbreviated, most: "0.000", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 99_000, prefix: .none, format: .abbreviated, most: "0.000...", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 100_000, prefix: .none, format: .abbreviated, most: "0.001", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 25_793_456, prefix: .none, format: .abbreviated, most: "0.258", least: ""),
    // Prefix None — Expanded
    ZatoshiStringRepresentationTests.Sample(zatoshi: 0, prefix: .none, format: .expanded, most: "0.000", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 99_000, prefix: .none, format: .expanded, most: "0.000", least: "99"),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 100_000, prefix: .none, format: .expanded, most: "0.001", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 25_793_456, prefix: .none, format: .expanded, most: "0.257", least: "93456"),
    // Dust guarantee: pool-balances sheet must show amounts down to a single zatoshi, so
    // `.expanded` must never drop a digit, even when the least-significant tail is all zeros.
    ZatoshiStringRepresentationTests.Sample(zatoshi: 1, prefix: .none, format: .expanded, most: "0.000", least: "00001"),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 14_090_955, prefix: .none, format: .expanded, most: "0.140", least: "90955"),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 14_000_000, prefix: .none, format: .expanded, most: "0.140", least: ""),
    // Prefix Plus — Abbreviated
    ZatoshiStringRepresentationTests.Sample(zatoshi: 0, prefix: .plus, format: .abbreviated, most: "+0.000", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 99_000, prefix: .plus, format: .abbreviated, most: "+0.000...", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 100_000, prefix: .plus, format: .abbreviated, most: "+0.001", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 25_793_456, prefix: .plus, format: .abbreviated, most: "+0.258", least: ""),
    // Prefix Plus — Expanded
    ZatoshiStringRepresentationTests.Sample(zatoshi: 0, prefix: .plus, format: .expanded, most: "+0.000", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 99_000, prefix: .plus, format: .expanded, most: "+0.000", least: "99"),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 100_000, prefix: .plus, format: .expanded, most: "+0.001", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 25_793_456, prefix: .plus, format: .expanded, most: "+0.257", least: "93456"),
    // Prefix Minus — Abbreviated
    ZatoshiStringRepresentationTests.Sample(zatoshi: 0, prefix: .minus, format: .abbreviated, most: "-0.000", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 99_000, prefix: .minus, format: .abbreviated, most: "-0.000...", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 100_000, prefix: .minus, format: .abbreviated, most: "-0.001", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 25_793_456, prefix: .minus, format: .abbreviated, most: "-0.258", least: ""),
    // Prefix Minus — Expanded
    ZatoshiStringRepresentationTests.Sample(zatoshi: 0, prefix: .minus, format: .expanded, most: "-0.000", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 99_000, prefix: .minus, format: .expanded, most: "-0.000", least: "99"),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 100_000, prefix: .minus, format: .expanded, most: "-0.001", least: ""),
    ZatoshiStringRepresentationTests.Sample(zatoshi: 25_793_456, prefix: .minus, format: .expanded, most: "-0.257", least: "93456")
]
