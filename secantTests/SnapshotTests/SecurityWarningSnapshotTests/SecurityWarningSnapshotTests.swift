//
//  SecurityWarningSnapshotTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 05.10.2023.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

class SecurityWarningSnapshotTests: XCTestCase {
    func testSecurityWarningSnapshot() throws {
        let store = Store(
            initialState: .initial
        ) {
            SecurityWarning()
                .dependency(\.appVersion, .mock)
        }

        addAttachments(SecurityWarningView(store: store))
        
        store.isAcknowledged = true

        addAttachments(SecurityWarningView(store: store))
    }
}
