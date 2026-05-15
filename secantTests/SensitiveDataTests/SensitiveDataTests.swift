//
//  SensitiveDataTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 06.02.2023.
//

import XCTest
@preconcurrency import MnemonicSwift
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

class SensitiveDataTests: XCTestCase {
    func testSeedPhraseConformsToUndescribable() throws {
        #if UNREDACTED
        XCTAssertNil(SeedPhrase.self as? Undescribable)
        #else
        XCTAssertNotNil(SeedPhrase.self as? Undescribable)
        #endif
    }
    
    func testBirthdayConformsToUndescribable() throws {
        #if UNREDACTED
        XCTAssertNil(Birthday.self as? Undescribable)
        #else
        XCTAssertNotNil(Birthday.self as? Undescribable)
        #endif
    }
    
    func testRedactableStringConformsToUndescribable() throws {
        #if UNREDACTED
        XCTAssertNil(RedactableString.self as? Undescribable)
        #else
        XCTAssertNotNil(RedactableString.self as? Undescribable)
        #endif
    }
    
    func testRedactableBlockHeightConformsToUndescribable() throws {
        #if UNREDACTED
        XCTAssertNil(RedactableBlockHeight.self as? Undescribable)
        #else
        XCTAssertNotNil(RedactableBlockHeight.self as? Undescribable)
        #endif
    }
        
    func testRedactableInt64ConformsToUndescribable() throws {
        #if UNREDACTED
        XCTAssertNil(RedactableInt64.self as? Undescribable)
        #else
        XCTAssertNotNil(RedactableInt64.self as? Undescribable)
        #endif
    }
}
