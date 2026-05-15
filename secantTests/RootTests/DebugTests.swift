//
//  DebugTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 02.03.2023.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

@MainActor
class DebugTests: XCTestCase {
    func testRescanBlockchain() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        
        await store.send(.debug(.rescanBlockchain)) { state in
            state.confirmationDialog = ConfirmationDialogState.rescanRequest()
        }
    }
    
    func testRescanBlockchain_Cancelling() async throws {
        var mockState = Root.State.initial
        
        mockState.confirmationDialog = ConfirmationDialogState.rescanRequest()
        
        let store = TestStore(
            initialState: mockState
        ) {
            Root()
        }
        
        await store.send(.debug(.cancelRescan)) { state in
            state.confirmationDialog = nil
        }
    }
    
    func testRescanBlockchain_QuickRescanClearance() async throws {
        var mockState = Root.State.initial
        
        mockState.confirmationDialog = ConfirmationDialogState.rescanRequest()
        
        let store = TestStore(
            initialState: mockState
        ) {
            Root()
        }

        store.dependencies.mainQueue = .immediate
        store.dependencies.sdkSynchronizer = .noOp

        await store.send(.confirmationDialog(.presented(.quickRescan))) { state in
            state.destinationState.internalDestination = .home
            state.destinationState.previousDestination = .welcome
            state.confirmationDialog = nil
        }
        
        await store.receive(.debug(.rewindDone(nil, .confirmationDialog(.presented(.quickRescan)))))
    }
    
    func testRescanBlockchain_FullRescanClearance() async throws {
        var mockState = Root.State.initial
        
        mockState.confirmationDialog = ConfirmationDialogState.rescanRequest()
        
        let store = TestStore(
            initialState: mockState
        ) {
            Root()
        }

        store.dependencies.mainQueue = .immediate
        store.dependencies.sdkSynchronizer = .noOp
                
        await store.send(.confirmationDialog(.presented(.fullRescan))) { state in
            state.destinationState.internalDestination = .home
            state.destinationState.previousDestination = .welcome
            state.confirmationDialog = nil
        }
        
        await store.receive(.debug(.rewindDone(nil, .confirmationDialog(.presented(.fullRescan)))))
    }
}
