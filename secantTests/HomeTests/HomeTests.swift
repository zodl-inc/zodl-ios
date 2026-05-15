//
//  HomeTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 02.06.2022.
//

@preconcurrency import Combine
import XCTest
import ComposableArchitecture
@testable import secant_testnet
@testable @preconcurrency import ZcashLightClientKit

class HomeTests: XCTestCase {
    /// The .onAppear action is important to register for the synchronizer state updates.
    /// The integration tests make sure registrations and side effects are properly implemented.
    @MainActor func testOnAppear() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            Home()
        }

        store.dependencies.mainQueue = .immediate
        store.dependencies.diskSpaceChecker = .mockEmptyDisk
        store.dependencies.sdkSynchronizer = .mocked()
        store.dependencies.reviewRequest = .noOp

        await store.send(.onAppear) { state in
            state.migratingDatabase = false
            state.walletBalancesState.migratingDatabase = true
        }

        var syncState: SynchronizerState = .zero
        syncState.syncStatus = .unprepared

        // long-living (cancelable) effects need to be properly canceled.
        // the .onDisappear action cancels the observer of the synchronizer status change.
        await store.send(.onDisappear)
        
        await store.finish()
    }

    @MainActor func testSynchronizerErrorBringsUpAlert() async {
        let testError = ZcashError.synchronizerNotPrepared

        var state = SynchronizerState.zero
        state.syncStatus = .error(testError)
        
        let store = TestStore(
            initialState: .initial
        ) {
            Home()
        }

        await store.send(.synchronizerStateChanged(state.redacted))

        await store.receive(.showSynchronizerErrorAlert(testError))
        
        await store.finish()
    }
}
