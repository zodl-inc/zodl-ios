//
//  BalanceBreakdownSnapshotTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 15.08.2022.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI
@testable import secant_testnet

class BalanceBreakdownSnapshotTests: XCTestCase {
    func testBalanceBreakdownSnapshot() throws {
        let store = Store(
            initialState: Balances.State(
                autoShieldingThreshold: Zatoshi(1_000_000),
                changePending: .zero,
                isShieldingFunds: false,
                pendingTransactions: .zero,
                syncProgressState: .initial,
                walletBalancesState: .initial
            )
        ) {
            Balances()
                .dependency(\.sdkSynchronizer, .noOp)
                .dependency(\.mainQueue, .immediate)
                .dependency(\.diskSpaceChecker, .mockEmptyDisk)
                .dependency(\.exchangeRate, .noOp)
        }
        
        addAttachments(BalancesView(store: store, tokenName: "ZEC"))
    }
    
    func testBalanceBreakdownSnapshot_HintBox() throws {
        let store = Store(
            initialState: Balances.State(
                autoShieldingThreshold: Zatoshi(1_000_000),
                changePending: .zero,
                isShieldingFunds: false,
                isHintBoxVisible: true,
                pendingTransactions: .zero,
                syncProgressState: .initial,
                walletBalancesState: .initial
            )
        ) {
            Balances()
                .dependency(\.sdkSynchronizer, .noOp)
                .dependency(\.mainQueue, .immediate)
                .dependency(\.diskSpaceChecker, .mockEmptyDisk)
                .dependency(\.exchangeRate, .noOp)
        }

        addAttachments(BalancesView(store: store, tokenName: "ZEC"))
    }
}
