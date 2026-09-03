//
//  ZatoshiTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 26.05.2022.
//

import Testing
import Foundation
import os
@testable import zodl_internal
@preconcurrency import ZODLSwiftWalletSDK

/// Serializes access to the process-global `NumberFormatter` singletons
/// (`NumberFormatter.zashiBalanceFormatter`, `.zcashNumberFormatter8FractionDigits`) across the
/// formatter-sensitive suites (`ZatoshiTests`, `ZatoshiStringRepresentationTests`,
/// `ZatoshiStringRepresentationCommaTests`), which Swift Testing runs in parallel by default. Any
/// test that sets a formatter's `locale` and then reads it must do so inside `shared.withLockUnchecked`
/// so an `en_US` regime never overlaps a `cs_CZ` regime on the same singleton.
enum FormatterTestGate {
    static let shared = OSAllocatedUnfairLock()
}

@Suite struct ZatoshiTests {
    let usNumberFormatter = NumberFormatter()

    init() {
        usNumberFormatter.maximumFractionDigits = 8
        usNumberFormatter.maximumIntegerDigits = 8
        usNumberFormatter.numberStyle = .decimal
        usNumberFormatter.usesGroupingSeparator = true
        usNumberFormatter.locale = Locale(identifier: "en_US")
    }

    @Test func lowerBound() throws {
        let number = Zatoshi(-Zatoshi.Constants.maxZatoshi - 1)

        #expect(
            -Zatoshi.Constants.maxZatoshi == number.amount,
            "Zatoshi tests: `testLowerBound` the value is expected to be clamped to lower bound but it's \(number.amount)"
        )
    }

    @Test func upperBound() throws {
        let number = Zatoshi(Zatoshi.Constants.maxZatoshi + 1)

        #expect(
            Zatoshi.Constants.maxZatoshi == number.amount,
            "Zatoshi tests: `testUpperBound` the value is expected to be clamped to upper bound but it's \(number.amount)"
        )
    }

    @Test func addingZatoshi() throws {
        let numberA1 = Zatoshi(100_000)
        let numberB1 = Zatoshi(200_000)
        let result1 = numberA1 + numberB1

        #expect(
            result1.amount == Zatoshi(300_000).amount,
            "Zatoshi tests: `testAddingZatoshi` the value is expected to be 300_000 but it's \(result1.amount)"
        )

        let numberA2 = Zatoshi(-100_000)
        let numberB2 = Zatoshi(200_000)
        let result2 = numberA2 + numberB2

        #expect(
            result2.amount == Zatoshi(100_000).amount,
            "Zatoshi tests: `testAddingZatoshi` the value is expected to be 100_000 but it's \(result2.amount)"
        )

        let numberA3 = Zatoshi(100_000)
        let numberB3 = Zatoshi(-200_000)
        let result3 = numberA3 + numberB3

        #expect(
            result3.amount == Zatoshi(-100_000).amount,
            "Zatoshi tests: `testAddingZatoshi` the value is expected to be -100_000 but it's \(result3.amount)"
        )

        let number = Zatoshi(Zatoshi.Constants.maxZatoshi)
        let result4 = number + number

        #expect(
            result4.amount == Zatoshi.Constants.maxZatoshi,
            "Zatoshi tests: `testAddingZatoshi` the value is expected to be clamped to upper bound but it's \(result4.amount)"
        )
    }

    @Test func subtractingZatoshi() throws {
        let numberA1 = Zatoshi(100_000)
        let numberB1 = Zatoshi(200_000)
        let result1 = numberA1 - numberB1

        #expect(
            result1.amount == Zatoshi(-100_000).amount,
            "Zatoshi tests: `testSubtractingZatoshi` the value is expected to be -100_000 but it's \(result1.amount)"
        )

        let numberA2 = Zatoshi(-100_000)
        let numberB2 = Zatoshi(200_000)
        let result2 = numberA2 - numberB2

        #expect(
            result2.amount == Zatoshi(-300_000).amount,
            "Zatoshi tests: `testSubtractingZatoshi` the value is expected to be -300_000 but it's \(result2.amount)"
        )

        let numberA3 = Zatoshi(100_000)
        let numberB3 = Zatoshi(-200_000)
        let result3 = numberA3 - numberB3

        #expect(
            result3.amount == Zatoshi(300_000).amount,
            "Zatoshi tests: `testSubtractingZatoshi` the value is expected to be 300_000 but it's \(result3.amount)"
        )

        let number = Zatoshi(-Zatoshi.Constants.maxZatoshi)
        let result4 = number + number

        #expect(
            result4.amount == -Zatoshi.Constants.maxZatoshi,
            "Zatoshi tests: `testSubtractingZatoshi` the value is expected to be clamped to lower bound but it's \(result4.amount)"
        )
    }

    @Test func humanReadable() throws {
        // result of this division is 1.4285714285714285714285714285714285714
        let number = Zatoshi.from(decimal: Decimal(200.0 / 140.0))

        // IMPORTANT: the INTERNAL value of number is still 1.4285714285714285714285714285714285714!!!
        // but decimalString is rounding it to maximumFractionDigits set to be 8

        // We can't compare it to double value 1.42857143 (or even Decimal(1.42857143))
        // so we convert it to string, in that case we are proving it to be rendered
        //    to the user exactly the way we want
        #expect(
            number.decimalString(formatter: usNumberFormatter) == "1.42857143",
            "Zatoshi tests: the value is expected to be 1.42857143 but it's \(number.decimalString())"
        )
    }

    @Test func usdToZecToUSD() throws {
        // The price of zec is $140, we want to send $200
        let usd2zec = NSDecimalNumber(decimal: 200.0 / 140.0)

        #expect(
            usd2zec.decimalString == "1.42857143",
            "Zatoshi tests: `testUSDtoZatoshiToUSD` the value is expected to be 1.42857143 but it's \(usd2zec.decimalString)"
        )

        // convert it back
        let zec2usd = NSDecimalNumber(decimal: usd2zec.decimalValue * 140.0)

        #expect(
            zec2usd.decimalString == "200",
            "Zatoshi tests: `testUSDtoZatoshiToUSD` the value is expected to be 200 but it's \(zec2usd.decimalString)"
        )
    }

    @Test func stringToZatoshi() throws {
        if let number = Zatoshi.from(decimalString: "200.0", formatter: usNumberFormatter) {
            #expect(
                number.decimalString(formatter: usNumberFormatter) == "200",
                "Zatoshi tests: `testStringToZec` the value is expected to be 200 but it's \(number.decimalString())"
            )
        } else {
            Issue.record("Zatoshi tests: `testStringToZatoshi` failed to convert number.")
        }

        if let number = Zatoshi.from(decimalString: "0.02836478949923", formatter: usNumberFormatter) {
            #expect(
                number.amount == 2_836_479,
                "Zatoshi tests: the value is expected to be 2_836_478 but it's \(number.amount)"
            )
        } else {
            Issue.record("Zatoshi tests: `testStringToZatoshi` failed to convert number.")
        }
    }

    @Test func zashiRounding() throws {
        FormatterTestGate.shared.withLockUnchecked {
            let zashiBalanceFormatter = NumberFormatter.zashiBalanceFormatter
            zashiBalanceFormatter.locale = Locale(identifier: "en_US")

            var balance = zashiBalanceFormatter.string(from: Zatoshi(11_440_000).decimalValue) ?? ""
            #expect(
                balance == "0.114",
                "Zatoshi tests: `testZashiRounding` the value is expected to be 0.114 but it's \(balance)"
            )

            balance = zashiBalanceFormatter.string(from: Zatoshi(11_410_000).decimalValue) ?? ""
            #expect(
                balance == "0.114",
                "Zatoshi tests: `testZashiRounding` the value is expected to be 0.114 but it's \(balance)"
            )

            balance = zashiBalanceFormatter.string(from: Zatoshi(11_440_000).decimalValue) ?? ""
            #expect(
                balance == "0.114",
                "Zatoshi tests: `testZashiRounding` the value is expected to be 0.114 but it's \(balance)"
            )

            balance = zashiBalanceFormatter.string(from: Zatoshi(11_450_000).decimalValue) ?? ""
            #expect(
                balance == "0.115",
                "Zatoshi tests: `testZashiRounding` the value is expected to be 0.115 but it's \(balance)"
            )

            balance = zashiBalanceFormatter.string(from: Zatoshi(11_490_000).decimalValue) ?? ""
            #expect(
                balance == "0.115",
                "Zatoshi tests: `testZashiRounding` the value is expected to be 0.115 but it's \(balance)"
            )
        }
    }
}
