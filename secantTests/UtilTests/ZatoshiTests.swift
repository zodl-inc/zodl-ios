//
//  ZatoshiTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 26.05.2022.
//

import XCTest
@testable import secant_testnet
@preconcurrency import ZcashLightClientKit

class ZatoshiTests: XCTestCase {
    let usNumberFormatter = NumberFormatter()
    
    override func setUp() {
        super.setUp()
        usNumberFormatter.maximumFractionDigits = 8
        usNumberFormatter.maximumIntegerDigits = 8
        usNumberFormatter.numberStyle = .decimal
        usNumberFormatter.usesGroupingSeparator = true
        usNumberFormatter.locale = Locale(identifier: "en_US")
    }

    func testLowerBound() throws {
        let number = Zatoshi(-Zatoshi.Constants.maxZatoshi - 1)
        
        XCTAssertEqual(
            -Zatoshi.Constants.maxZatoshi,
            number.amount,
            "Zatoshi tests: `testLowerBound` the value is expected to be clamped to lower bound but it's \(number.amount)"
        )
    }

    func testUpperBound() throws {
        let number = Zatoshi(Zatoshi.Constants.maxZatoshi + 1)

        XCTAssertEqual(
            Zatoshi.Constants.maxZatoshi,
            number.amount,
            "Zatoshi tests: `testUpperBound` the value is expected to be clamped to upper bound but it's \(number.amount)"
        )
    }
    
    func testAddingZatoshi() throws {
        let numberA1 = Zatoshi(100_000)
        let numberB1 = Zatoshi(200_000)
        let result1 = numberA1 + numberB1
        
        XCTAssertEqual(
            result1.amount,
            Zatoshi(300_000).amount,
            "Zatoshi tests: `testAddingZatoshi` the value is expected to be 300_000 but it's \(result1.amount)"
        )

        let numberA2 = Zatoshi(-100_000)
        let numberB2 = Zatoshi(200_000)
        let result2 = numberA2 + numberB2
        
        XCTAssertEqual(
            result2.amount,
            Zatoshi(100_000).amount,
            "Zatoshi tests: `testAddingZatoshi` the value is expected to be 100_000 but it's \(result2.amount)"
        )
        
        let numberA3 = Zatoshi(100_000)
        let numberB3 = Zatoshi(-200_000)
        let result3 = numberA3 + numberB3
        
        XCTAssertEqual(
            result3.amount,
            Zatoshi(-100_000).amount,
            "Zatoshi tests: `testAddingZatoshi` the value is expected to be -100_000 but it's \(result3.amount)"
        )

        let number = Zatoshi(Zatoshi.Constants.maxZatoshi)
        let result4 = number + number
        
        XCTAssertEqual(
            result4.amount,
            Zatoshi.Constants.maxZatoshi,
            "Zatoshi tests: `testAddingZatoshi` the value is expected to be clamped to upper bound but it's \(result4.amount)"
        )
    }
    
    func testSubtractingZatoshi() throws {
        let numberA1 = Zatoshi(100_000)
        let numberB1 = Zatoshi(200_000)
        let result1 = numberA1 - numberB1
        
        XCTAssertEqual(
            result1.amount,
            Zatoshi(-100_000).amount,
            "Zatoshi tests: `testSubtractingZatoshi` the value is expected to be -100_000 but it's \(result1.amount)"
        )

        let numberA2 = Zatoshi(-100_000)
        let numberB2 = Zatoshi(200_000)
        let result2 = numberA2 - numberB2
        
        XCTAssertEqual(
            result2.amount,
            Zatoshi(-300_000).amount,
            "Zatoshi tests: `testSubtractingZatoshi` the value is expected to be -300_000 but it's \(result2.amount)"
        )
        
        let numberA3 = Zatoshi(100_000)
        let numberB3 = Zatoshi(-200_000)
        let result3 = numberA3 - numberB3
        
        XCTAssertEqual(
            result3.amount,
            Zatoshi(300_000).amount,
            "Zatoshi tests: `testSubtractingZatoshi` the value is expected to be 300_000 but it's \(result3.amount)"
        )

        let number = Zatoshi(-Zatoshi.Constants.maxZatoshi)
        let result4 = number + number
        
        XCTAssertEqual(
            result4.amount,
            -Zatoshi.Constants.maxZatoshi,
            "Zatoshi tests: `testSubtractingZatoshi` the value is expected to be clamped to lower bound but it's \(result4.amount)"
        )
    }
    
    func testHumanReadable() throws {
        // result of this division is 1.4285714285714285714285714285714285714
        let number = Zatoshi.from(decimal: Decimal(200.0 / 140.0))
        
        // IMPORTANT: the INTERNAL value of number is still 1.4285714285714285714285714285714285714!!!
        // but decimalString is rounding it to maximumFractionDigits set to be 8
        
        // We can't compare it to double value 1.42857143 (or even Decimal(1.42857143))
        // so we convert it to string, in that case we are proving it to be rendered
        //    to the user exactly the way we want
        XCTAssertEqual(
            number.decimalString(formatter: usNumberFormatter),
            "1.42857143",
            "Zatoshi tests: the value is expected to be 1.42857143 but it's \(number.decimalString())"
        )
    }

    func testUSDtoZecToUSD() throws {
        // The price of zec is $140, we want to send $200
        let usd2zec = NSDecimalNumber(decimal: 200.0 / 140.0)

        XCTAssertEqual(
            usd2zec.decimalString,
            "1.42857143",
            "Zatoshi tests: `testUSDtoZatoshiToUSD` the value is expected to be 1.42857143 but it's \(usd2zec.decimalString)"
        )
        
        // convert it back
        let zec2usd = NSDecimalNumber(decimal: usd2zec.decimalValue * 140.0)

        XCTAssertEqual(
            zec2usd.decimalString,
            "200",
            "Zatoshi tests: `testUSDtoZatoshiToUSD` the value is expected to be 200 but it's \(zec2usd.decimalString)"
        )
    }
    
    func testStringToZatoshi() throws {
        if let number = Zatoshi.from(decimalString: "200.0", formatter: usNumberFormatter) {
            XCTAssertEqual(
                number.decimalString(formatter: usNumberFormatter),
                "200",
                "Zatoshi tests: `testStringToZec` the value is expected to be 200 but it's \(number.decimalString())"
            )
        } else {
            XCTFail("Zatoshi tests: `testStringToZatoshi` failed to convert number.")
        }

        if let number = Zatoshi.from(decimalString: "0.02836478949923", formatter: usNumberFormatter) {
            XCTAssertEqual(
                number.amount,
                2_836_479,
                "Zatoshi tests: the value is expected to be 2_836_478 but it's \(number.amount)"
            )
        } else {
            XCTFail("Zatoshi tests: `testStringToZatoshi` failed to convert number.")
        }
    }
    
    func testZashiRounding() throws {
        let zashiBalanceFormatter = NumberFormatter.zashiBalanceFormatter
        zashiBalanceFormatter.locale = Locale(identifier: "en_US")
        
        var balance = zashiBalanceFormatter.string(from: Zatoshi(11_440_000).decimalValue) ?? ""
        XCTAssertEqual(
            balance,
            "0.114",
            "Zatoshi tests: `testZashiRounding` the value is expected to be 0.114 but it's \(balance)"
        )

        balance = zashiBalanceFormatter.string(from: Zatoshi(11_410_000).decimalValue) ?? ""
        XCTAssertEqual(
            balance,
            "0.114",
            "Zatoshi tests: `testZashiRounding` the value is expected to be 0.114 but it's \(balance)"
        )

        balance = zashiBalanceFormatter.string(from: Zatoshi(11_440_000).decimalValue) ?? ""
        XCTAssertEqual(
            balance,
            "0.114",
            "Zatoshi tests: `testZashiRounding` the value is expected to be 0.114 but it's \(balance)"
        )

        balance = zashiBalanceFormatter.string(from: Zatoshi(11_450_000).decimalValue) ?? ""
        XCTAssertEqual(
            balance,
            "0.115",
            "Zatoshi tests: `testZashiRounding` the value is expected to be 0.115 but it's \(balance)"
        )

        balance = zashiBalanceFormatter.string(from: Zatoshi(11_490_000).decimalValue) ?? ""
        XCTAssertEqual(
            balance,
            "0.115",
            "Zatoshi tests: `testZashiRounding` the value is expected to be 0.115 but it's \(balance)"
        )
    }
}
