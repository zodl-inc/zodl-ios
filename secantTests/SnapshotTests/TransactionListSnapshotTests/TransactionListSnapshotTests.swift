//
//  TransactionListSnapshotTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 27.06.2022.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

class TransactionListSnapshotTests: XCTestCase {
    func testFullTransactionListSnapshot() throws {
        let store = StoreOf<TransactionList>(
            initialState: .placeholder
        ) {
            TransactionList()
                .dependency(\.sdkSynchronizer, .mock)
                .dependency(\.mainQueue, .immediate)
        }
        
        // landing wallet events screen
        addAttachments(
            name: "\(#function)_initial",
            TransactionListView(store: store, tokenName: "ZEC")
        )
    }
}
