//
//  RestoreWalletTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 04.01.2024.
//

import XCTest
@preconcurrency import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

@MainActor
final class RestoreWalletTests: XCTestCase {
    func testIsRestoringWallet() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        
        store.dependencies.mainQueue = .immediate
        store.dependencies.mnemonic = .noOp
        store.dependencies.walletStatusPanel = .noOp
        store.dependencies.sdkSynchronizer = .noOp
        store.dependencies.walletStorage = .noOp
        store.dependencies.userDefaults = .noOp
        store.dependencies.autolockHandler = .noOp
        store.dependencies.exchangeRate = .noOp

        await store.send(.onboarding(.importWallet(.initializeSDK))) { state in
            state.isRestoringWallet = true
        }
        
        await store.receive(.initialization(.initializeSDK(.restoreWallet)))
        
        await store.receive(.initialization(.initializationSuccessfullyDone(nil)))

        await store.receive(.initialization(.registerForSynchronizersUpdate))

        await store.send(.cancelAllRunningEffects)
        
        await store.finish()
    }
    
    func testIsRestoringWalletFinished() async throws {
        var state = Root.State.initial
        state.isRestoringWallet = true
        
        let store = TestStore(
            initialState: state
        ) {
            Root()
        }
        
        store.dependencies.mainQueue = .immediate
        store.dependencies.mnemonic = .noOp
        store.dependencies.walletStatusPanel = .noOp
        store.dependencies.sdkSynchronizer = .noOp
        store.dependencies.walletStorage = .noOp
        store.dependencies.userDefaults = .noOp

        var syncState: SynchronizerState = .zero
        syncState.syncStatus = .upToDate

        await store.send(.synchronizerStateChanged(syncState.redacted))
        
        await store.receive(.initialization(.checkRestoreWalletFlag(syncState.syncStatus))) { state in
            state.isRestoringWallet = false
        }

        await store.finish()
    }
}
