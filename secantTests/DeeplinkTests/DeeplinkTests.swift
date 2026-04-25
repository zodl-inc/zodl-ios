//
//  DeeplinkTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 16.06.2022.
//

import Combine
import XCTest
import ComposableArchitecture
import ZcashLightClientKit
import Deeplink
import SDKSynchronizer
import Root
@testable import secant_testnet

@MainActor
class DeeplinkTests: XCTestCase {
    func testActionDeeplinkHome_SameDestinationLevel() async throws {
        var appState = Root.State.initial
        appState.destinationState.destination = .welcome
        
        let store = TestStore(
            initialState: appState
        ) {
            Root()
        }
        
        await store.send(.destination(.deeplinkHome)) { state in
            state.destinationState.destination = .home
        }
        
        await store.finish()
    }

    func testActionDeeplinkHome_GeetingBack() async throws {
        var appState = Root.State.initial
        appState.destinationState.destination = .home
        
        let store = TestStore(
            initialState: appState
        ) {
            Root()
        }
        
        await store.send(.destination(.deeplinkHome)) { state in
            state.destinationState.destination = .home
        }
        
        await store.finish()
    }
    
    func testActionDeeplinkSend() async throws {
        var appState = Root.State.initial
        appState.destinationState.destination = .welcome
        
        let store = TestStore(
            initialState: appState
        ) {
            Root()
        }
        
        let amount = Zatoshi(123_000_000)
        let address = "address"
        let memo = "testing some memo"
        
        await store.send(.destination(.deeplinkSend(amount, address, memo))) { state in
            state.destinationState.destination = .home
            state.path = .sendCoordFlow
            state.sendCoordFlowState.sendFormState.memoState.text = memo
        }
        
        await store.finish()
    }

    func testReceiveURLParsing() throws {
        guard let url = URL(string: "zcash:///home/receive") else {
            return XCTFail("Deeplink: 'testReceiveURLParsing' URL is expected to be valid.")
        }

        let result = try Deeplink().resolveDeeplinkURL(url, networkType: .testnet, isValidZcashAddress: { _, _ in false })

        XCTAssertEqual(result, Deeplink.Destination.receive)
    }

    func testActionDeeplinkReceive() async throws {
        var appState = Root.State.initial
        appState.destinationState.destination = .welcome

        let store = TestStore(
            initialState: appState
        ) {
            Root()
        }

        await store.send(.destination(.deeplinkReceive)) { state in
            state.destinationState.destination = .home
            state.path = .receive
        }

        await store.finish()
    }

    func testDeeplinkRequest_Received_Receive() async throws {
        var appState = Root.State.initial
        appState.destinationState.destination = .welcome
        appState.appInitializationState = .initialized

        let store = TestStore(
            initialState: appState
        ) {
            Root()
        }

        store.dependencies.deeplink = DeeplinkClient(
            resolveDeeplinkURL: { _, _, _ in Deeplink.Destination.receive }
        )
        store.dependencies.sdkSynchronizer = SDKSynchronizerClient.mocked(
            latestState: {
                var state = SynchronizerState.zero
                state.syncStatus = .upToDate
                return state
            }
        )
        store.dependencies.walletConfigProvider = .noOp

        guard let url = URL(string: "zcash:///home/receive") else {
            return XCTFail("Deeplink: 'testDeeplinkRequest_Received_Receive' URL is expected to be valid.")
        }

        await store.send(.destination(.deeplink(url)))

        await store.receive(.destination(.deeplinkReceive)) { state in
            state.destinationState.destination = .home
            state.path = .receive
        }

        await store.finish()
    }

    func testHomeURLParsing() throws {
        guard let url = URL(string: "zcash:///home") else {
            return XCTFail("Deeplink: 'testDeeplinkRequest_homeURL' URL is expected to be valid.")
        }

        let result = try Deeplink().resolveDeeplinkURL(url, networkType: .testnet, isValidZcashAddress: { _, _ in false })
        
        XCTAssertEqual(result, Deeplink.Destination.home)
    }

    func testDeeplinkRequest_Received_Home() async throws {
        var appState = Root.State.initial
        appState.destinationState.destination = .welcome
        appState.appInitializationState = .initialized
        
        let store = TestStore(
            initialState: appState
        ) {
            Root()
        }
        
        store.dependencies.deeplink = DeeplinkClient(
            resolveDeeplinkURL: { _, _, _ in Deeplink.Destination.home }
        )
        store.dependencies.sdkSynchronizer = SDKSynchronizerClient.mocked(
            latestState: {
                var state = SynchronizerState.zero
                state.syncStatus = .upToDate
                return state
            }
        )
        store.dependencies.walletConfigProvider = .noOp

        guard let url = URL(string: "zcash:///home") else {
            return XCTFail("Deeplink: 'testDeeplinkRequest_homeURL' URL is expected to be valid.")
        }
        
        await store.send(.destination(.deeplink(url)))
        
        await store.receive(.destination(.deeplinkHome)) { state in
            state.destinationState.destination = .home
        }
        
        await store.finish()
    }

    func testsendURLParsing() throws {
        guard let url = URL(string: "zcash:///home/send?address=address&memo=some%20text&amount=123000000") else {
            return XCTFail("Deeplink: 'testDeeplinkRequest_sendURL_amount' URL is expected to be valid.")
        }

        let result = try Deeplink().resolveDeeplinkURL(url, networkType: .testnet, isValidZcashAddress: { _, _ in false })
        
        XCTAssertEqual(result, Deeplink.Destination.send(amount: 123_000_000, address: "address", memo: "some text"))
    }
    
    func testDeeplinkRequest_Received_Send() async throws {
        var appState = Root.State.initial
        appState.destinationState.destination = .welcome
        appState.appInitializationState = .initialized
        
        let store = TestStore(
            initialState: appState
        ) {
            Root()
        }
        
        store.dependencies.deeplink = DeeplinkClient(
            resolveDeeplinkURL: { _, _, _ in Deeplink.Destination.send(amount: 123_000_000, address: "address", memo: "some text") }
        )
        store.dependencies.sdkSynchronizer = SDKSynchronizerClient.mocked(
            latestState: {
                var state = SynchronizerState.zero
                state.syncStatus = .upToDate
                return state
            }
        )
        
        guard let url = URL(string: "zcash:///home/send?address=address&memo=some%20text&amount=123000000") else {
            return XCTFail("Deeplink: 'testDeeplinkRequest_sendURL_amount' URL is expected to be valid.")
        }

        await store.send(.destination(.deeplink(url)))
        
        let amount = Zatoshi(123_000_000)
        let address = "address"
        let memo = "some text"

        await store.receive(.destination(.deeplinkSend(amount, address, memo))) { state in
            state.destinationState.destination = .home
            state.path = .sendCoordFlow
            state.sendCoordFlowState.sendFormState.memoState.text = memo
        }
        
        await store.finish()
    }
}
