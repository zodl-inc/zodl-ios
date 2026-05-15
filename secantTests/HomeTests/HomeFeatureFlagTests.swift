//
//  HomeFeatureFlagTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 23.02.2023.
//

import XCTest
@testable import secant_testnet

class HomeFeatureFlagTests: XCTestCase {
    override func setUp() {
        super.setUp()

        UserDefaultsWalletConfigStorage().clearAll()
    }

    func testShowFiatConversionOffByDefault() throws {
        XCTAssertFalse(WalletConfig.initial.isEnabled(.showFiatConversion))
    }
}
