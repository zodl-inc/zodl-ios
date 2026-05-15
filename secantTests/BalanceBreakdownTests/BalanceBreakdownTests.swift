//
//  BalanceBreakdownTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 15.08.2022.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@preconcurrency import Combine
@testable import secant_testnet

@MainActor
class BalanceBreakdownTests: XCTestCase {
    func testShieldFundsFails() async throws {
        let store = TestStore(
            initialState: .placeholder
        ) {
            Balances()
        }

        store.dependencies.sdkSynchronizer = .mocked(shieldFunds: { _, _, _ in throw ZcashError.synchronizerNotPrepared })
        store.dependencies.derivationTool = .liveValue
        store.dependencies.mnemonic = .mock
        store.dependencies.walletStorage.exportWallet = { .placeholder }
        store.dependencies.walletStorage.areKeysPresent = { true }

        await store.send(.shieldFunds) { state in
            state.isShieldingFunds = true
        }
        
        let zcashError = ZcashError.unknown("sdkSynchronizer.proposeShielding")
        
        await store.receive(.shieldFundsFailure(zcashError)) { state in
            state.isShieldingFunds = false
            state.alert = AlertState.shieldFundsFailure(zcashError)
        }

        // long-living (cancelable) effects need to be properly canceled.
        // the .onDisappear action cancels the observer of the synchronizer status change.
        await store.send(.onDisappear)
        
        await store.finish()
    }

    func testShieldFundsButtonDisabledWhenNoShieldableFunds() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            Balances()
        }
        
        store.dependencies.mainQueue = .immediate
        store.dependencies.sdkSynchronizer = .noOp
        
        await store.send(.onAppear) { state in
            state.autoShieldingThreshold = ZcashSDKEnvironment.liveValue.shieldingThreshold
        }

        XCTAssertFalse(store.state.isShieldingFunds)
        XCTAssertFalse(store.state.isShieldableBalanceAvailable)
        XCTAssertTrue(store.state.isShieldingButtonDisabled)
    }

    func testShieldFundsButtonEnabledWhenShieldableFundsAvailable() async throws {
        let store = TestStore(
            initialState: Balances.State(
                autoShieldingThreshold: Zatoshi(1_000_000),
                changePending: .zero,
                isShieldingFunds: false,
                pendingTransactions: .zero,
                syncProgressState: .initial,
                transparentBalance: Zatoshi(1_000_000),
                walletBalancesState: .initial
            )
        ) {
            Balances()
        }

        XCTAssertFalse(store.state.isShieldingFunds)
        XCTAssertTrue(store.state.isShieldableBalanceAvailable)
        XCTAssertFalse(store.state.isShieldingButtonDisabled)
    }

    func testShieldFundsButtonDisabledWhenShieldableFundsAvailableAndShielding() async throws {
        let store = TestStore(
            initialState: Balances.State(
                autoShieldingThreshold: Zatoshi(1_000_000),
                changePending: .zero,
                isShieldingFunds: true,
                pendingTransactions: .zero,
                syncProgressState: .initial,
                transparentBalance: Zatoshi(1_000_000),
                walletBalancesState: .initial
            )
        ) {
            Balances()
        }

        XCTAssertTrue(store.state.isShieldingFunds)
        XCTAssertTrue(store.state.isShieldableBalanceAvailable)
        XCTAssertTrue(store.state.isShieldingButtonDisabled)
    }
    
    func testShowHintbox() async throws {
        var initialState = Balances.State.initial
        initialState.isHintBoxVisible = false

        let store = TestStore(
            initialState: initialState
        ) {
            Balances()
        }
        
        await store.send(.updateHintBoxVisibility(true)) { state in
            state.isHintBoxVisible = true
        }
        
        await store.finish()
    }
    
    func testHideHintbox() async throws {
        var initialState = Balances.State.initial
        initialState.isHintBoxVisible = true
        
        let store = TestStore(
            initialState: initialState
        ) {
            Balances()
        }
        
        await store.send(.updateHintBoxVisibility(false)) { state in
            state.isHintBoxVisible = false
        }
        
        await store.finish()
    }
}
