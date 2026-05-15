//
//  PrivateDataConsentSnapshotTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 01.11.2023.
//

import XCTest
import ComposableArchitecture
@testable import secant_testnet

class PrivateDataConsentSnapshotTests: XCTestCase {
    func testPrivateDataConsentSnapshot() throws {
        let store = Store(
            initialState: .initial
        ) {
            PrivateDataConsent()
                .dependency(\.databaseFiles, .noOp)
        }

        addAttachments(PrivateDataConsentView(store: store))
        
        // TODO: [#1349] fix the tests https://github.com/Electric-Coin-Company/zashi-ios/issues/1349
//        ViewStore(store, observe: { $0 }).send(.binding(.set(\.$isAcknowledged, true)))
//
//        addAttachments(PrivateDataConsentView(store: store))
    }
}
