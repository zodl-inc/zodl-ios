//
//  ReceiveTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 05.01.2023.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

@MainActor
class ReceiveTests: XCTestCase {
    // swiftlint:disable line_length
    let uAddressEncoding = "utest1zkkkjfxkamagznjr6ayemffj2d2gacdwpzcyw669pvg06xevzqslpmm27zjsctlkstl2vsw62xrjktmzqcu4yu9zdhdxqz3kafa4j2q85y6mv74rzjcgjg8c0ytrg7dwyzwtgnuc76h"
    
    func testCopyTransparentAddressToPasteboard() async throws {
        let testPasteboard = PasteboardClient.testPasteboard
        let uAddress = try UnifiedAddress(encoding: uAddressEncoding, network: .testnet)

        let store = TestStore(
            initialState: Receive.State(uAddress: uAddress)
        ) {
            Receive()
        }
        
        store.dependencies.pasteboard = testPasteboard

        let expectedAddress = try uAddress.transparentReceiver().stringEncoded

        await store.send(.copyToPastboard(expectedAddress.redacted))
        
        XCTAssertEqual(
            testPasteboard.getString()?.data,
            expectedAddress,
            "Receive: `testCopyTransparentAddressToPasteboard` is expected to match the input `\(expectedAddress)`"
        )
        
        await store.finish()
    }
    
    func testCopyUnifiedAddressToPasteboard() async throws {
        let testPasteboard = PasteboardClient.testPasteboard
        let uAddress = try UnifiedAddress(encoding: uAddressEncoding, network: .testnet)

        let store = TestStore(
            initialState: Receive.State(uAddress: uAddress)
        ) {
            Receive()
        }
        
        store.dependencies.pasteboard = testPasteboard

        await store.send(.copyToPastboard(uAddress.stringEncoded.redacted))
        
        XCTAssertEqual(
            testPasteboard.getString()?.data,
            uAddress.stringEncoded,
            "Receive: `testCopyUnifiedAddressToPasteboard` is expected to match the input `\(uAddress.stringEncoded)`"
        )
        
        await store.finish()
    }
    
    func testCopySaplingAddressToPasteboard() async throws {
        let testPasteboard = PasteboardClient.testPasteboard
        let uAddress = try UnifiedAddress(encoding: uAddressEncoding, network: .testnet)
        
        let store = TestStore(
            initialState: Receive.State(uAddress: uAddress)
        ) {
            Receive()
        }
        
        store.dependencies.pasteboard = testPasteboard

        let expectedAddress = try uAddress.saplingReceiver().stringEncoded

        await store.send(.copyToPastboard(expectedAddress.redacted))
        
        XCTAssertEqual(
            testPasteboard.getString()?.data,
            expectedAddress,
            "Receive: `testCopySaplingAddressToPasteboard` is expected to match the input `\(expectedAddress)`"
        )
        
        await store.finish()
    }
    
    func testShareTransparentAddress() async throws {
        let uAddress = try UnifiedAddress(encoding: uAddressEncoding, network: .testnet)

        let store = TestStore(
            initialState: Receive.State(uAddress: uAddress)
        ) {
            Receive()
        }

        let expectedAddress = try uAddress.transparentReceiver().stringEncoded

        await store.send(.shareQR(expectedAddress.redacted)) { state in
            state.addressToShare = expectedAddress.redacted
        }
        
        await store.finish()
    }
    
    func testShareUnifiedAddress() async throws {
        let uAddress = try UnifiedAddress(encoding: uAddressEncoding, network: .testnet)

        let store = TestStore(
            initialState: Receive.State(uAddress: uAddress)
        ) {
            Receive()
        }

        await store.send(.shareQR(uAddress.stringEncoded.redacted)) { state in
            state.addressToShare = uAddress.stringEncoded.redacted
        }
        
        await store.finish()
    }

    func testShareSaplingAddress() async throws {
        let uAddress = try UnifiedAddress(encoding: uAddressEncoding, network: .testnet)

        let store = TestStore(
            initialState: Receive.State(uAddress: uAddress)
        ) {
            Receive()
        }

        let expectedAddress = try uAddress.saplingReceiver().stringEncoded

        await store.send(.shareQR(expectedAddress.redacted)) { state in
            state.addressToShare = expectedAddress.redacted
        }
        
        await store.finish()
    }
}
