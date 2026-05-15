//
//  WelcomeSnapshotTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 06.06.2022.
//

import XCTest
import ComposableArchitecture
@testable import secant_testnet

class WelcomeSnapshotTests: XCTestCase {
    func testWelcomeSnapshot() throws {
        let store = Store(
            initialState: .initial
        ) {
            Welcome()
        }

        addAttachments(WelcomeView(store: store))
    }
}
