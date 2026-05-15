//
//  ReceiveSnapshotTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 05.01.2023.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI
@testable import secant_testnet

class ReceiveSnapshotTests: XCTestCase {
    func testReceiveSnapshot_testnet() throws {
        // swiftlint:disable line_length
        let uAddress = try UnifiedAddress(
            encoding: "utest1zkkkjfxkamagznjr6ayemffj2d2gacdwpzcyw669pvg06xevzqslpmm27zjsctlkstl2vsw62xrjktmzqcu4yu9zdhdxqz3kafa4j2q85y6mv74rzjcgjg8c0ytrg7dwyzwtgnuc76h",
            network: .testnet
        )

        let networkType = NetworkType.testnet
        
        let store = Store(
            initialState: Receive.State(uAddress: uAddress)
        ) {
            Receive()
                .dependency(\.walletConfigProvider, .noOp)
        }
        
        addAttachments(ReceiveView(store: store, networkType: networkType))
    }
    
    func testReceiveSnapshot_mainnet() throws {
        // swiftlint:disable line_length
        let uAddress = try UnifiedAddress(
            encoding: "utest1zkkkjfxkamagznjr6ayemffj2d2gacdwpzcyw669pvg06xevzqslpmm27zjsctlkstl2vsw62xrjktmzqcu4yu9zdhdxqz3kafa4j2q85y6mv74rzjcgjg8c0ytrg7dwyzwtgnuc76h",
            network: .testnet
        )

        let networkType = NetworkType.mainnet
        
        let store = Store(
            initialState: Receive.State(uAddress: uAddress)
        ) {
            Receive()
                .dependency(\.walletConfigProvider, .noOp)
        }
        
        addAttachments(ReceiveView(store: store, networkType: networkType))
    }
}
