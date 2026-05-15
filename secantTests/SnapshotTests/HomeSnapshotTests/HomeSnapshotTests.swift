//
//  HomeSnapshotTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 13.06.2022.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

class HomeSnapshotTests: XCTestCase {
    func testHomeSnapshot() throws {
        let transactionsHelper: [TransactionStateMockHelper] = [
            TransactionStateMockHelper(date: 1651039202, amount: Zatoshi(1), status: .paid, uuid: "1"),
            TransactionStateMockHelper(date: 1651039101, amount: Zatoshi(2), status: .sending, uuid: "2"),
            TransactionStateMockHelper(date: 1651039000, amount: Zatoshi(3), status: .received, uuid: "3"),
            TransactionStateMockHelper(date: 1651039505, amount: Zatoshi(4), status: .failed, uuid: "4")
        ]
        
        let transactionList: [TransactionState] = transactionsHelper.map {
            var transaction = TransactionState.placeholder(
                amount: $0.amount,
                fee: Zatoshi(10),
                shielded: $0.shielded,
                status: $0.status,
                timestamp: $0.date,
                uuid: $0.uuid
            )
            transaction.zAddress = "t1gXqfSSQt6WfpwyuCU3Wi7sSVZ66DYQ3Po"
            
            return transaction
        }
        
        let store = StoreOf<Home>(
            initialState: .init(
                syncProgressState: .initial,
                transactionListState: .init(transactionList: IdentifiedArrayOf(uniqueElements: transactionList)),
                walletBalancesState: .initial,
                walletConfig: .initial
            )
        ) {
            Home()
                .dependency(\.diskSpaceChecker, .mockEmptyDisk)
                .dependency(\.sdkSynchronizer, .noOp)
                .dependency(\.mainQueue, .immediate)
                .dependency(\.reviewRequest, .noOp)
                .dependency(\.exchangeRate, .noOp)
        }

        // landing home screen
        addAttachments(HomeView(store: store, tokenName: "ZEC"))
    }
}
