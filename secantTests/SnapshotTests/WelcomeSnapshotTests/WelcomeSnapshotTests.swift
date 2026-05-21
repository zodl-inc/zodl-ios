//
//  WelcomeSnapshotTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 06.06.2022.
//

import XCTest
import ComposableArchitecture
@testable import zashi_internal

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
