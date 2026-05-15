//
//  ZatoshiStringRepresentationCommaTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 2024-02-12.
//

import XCTest
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

final class ZatoshiStringRepresentationCommaTests: XCTestCase {
    override func setUp() {
        super.setUp()
        
        let zashiBalanceFormatter = NumberFormatter.zashiBalanceFormatter
        zashiBalanceFormatter.locale = Locale(identifier: "cs_CZ")
        
        let zashiNumberFormatter = NumberFormatter.zcashNumberFormatter8FractionDigits
        zashiNumberFormatter.locale = Locale(identifier: "cs_CZ")
    }

    // MARK: - Fee Format
    
    func testFeeFormat() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(0))
        
        XCTAssertEqual(zatoshiStringRepresentation.feeFormat, "Typical Fee < 0,001")
    }

    // MARK: - Prefix None
    
    func testPrefixNone_Abbreviated_ZeroZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(0))
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "0,000")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixNone_Abbreviated_LessThan100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(99_000))
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "0,000...")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixNone_Abbreviated_100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(100_000))
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "0,001")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixNone_Abbreviated_MoreThan100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(25_793_456))
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "0,258")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }
    
    func testPrefixNone_Expanded_ZeroZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(0), format: .expanded)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "0,000")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixNone_Expanded_LessThan100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(99_000), format: .expanded)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "0,000")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "99")
    }

    func testPrefixNone_Expanded_100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(100_000), format: .expanded)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "0,001")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixNone_Expanded_MoreThan100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(25_793_456), format: .expanded)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "0,257")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "93456")
    }
    
    // MARK: - Prefix Plus
    
    func testPrefixPlus_Abbreviated_ZeroZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(0), prefixSymbol: .plus)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "+0,000")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixPlus_Abbreviated_LessThan100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(99_000), prefixSymbol: .plus)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "+0,000...")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixPlus_Abbreviated_100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(100_000), prefixSymbol: .plus)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "+0,001")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixPlus_Abbreviated_MoreThan100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(25_793_456), prefixSymbol: .plus)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "+0,258")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }
    
    func testPrefixPlus_Expanded_ZeroZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(0), prefixSymbol: .plus, format: .expanded)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "+0,000")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixPlus_Expanded_LessThan100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(99_000), prefixSymbol: .plus, format: .expanded)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "+0,000")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "99")
    }

    func testPrefixPlus_Expanded_100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(100_000), prefixSymbol: .plus, format: .expanded)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "+0,001")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixPlus_Expanded_MoreThan100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(25_793_456), prefixSymbol: .plus, format: .expanded)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "+0,257")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "93456")
    }
    
    // MARK: - Prefix Minus
    
    func testPrefixMinus_Abbreviated_ZeroZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(0), prefixSymbol: .minus)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "-0,000")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixMinus_Abbreviated_LessThan100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(99_000), prefixSymbol: .minus)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "-0,000...")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixMinus_Abbreviated_100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(100_000), prefixSymbol: .minus)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "-0,001")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixMinus_Abbreviated_MoreThan100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(25_793_456), prefixSymbol: .minus)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "-0,258")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }
    
    func testPrefixMinus_Expanded_ZeroZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(0), prefixSymbol: .minus, format: .expanded)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "-0,000")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixMinus_Expanded_LessThan100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(99_000), prefixSymbol: .minus, format: .expanded)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "-0,000")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "99")
    }

    func testPrefixMinus_Expanded_100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(100_000), prefixSymbol: .minus, format: .expanded)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "-0,001")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "")
    }

    func testPrefixMinus_Expanded_MoreThan100kZatoshi() throws {
        let zatoshiStringRepresentation = ZatoshiStringRepresentation(Zatoshi(25_793_456), prefixSymbol: .minus, format: .expanded)
        
        XCTAssertEqual(zatoshiStringRepresentation.mostSignificantDigits, "-0,257")
        XCTAssertEqual(zatoshiStringRepresentation.leastSignificantDigits, "93456")
    }
}
