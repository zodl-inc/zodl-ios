//
//  ScanTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 17.05.2022.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

@MainActor
class ScanTests: XCTestCase {
    func testOnAppearResetValues() async throws {
        let store = TestStore(
            initialState:
                Scan.State(
                    isTorchAvailable: true,
                    isTorchOn: true
                )
        ) {
            Scan()
        }

        store.dependencies.captureDevice = .noOp
        
        await store.send(.onAppear) { state in
            state.isTorchAvailable = false
            state.isTorchOn = false
            state.isCameraEnabled = false
            state.info = String(localizable: .scanCameraSettings)
        }
        
        await store.finish()
    }
    
    func testTorchOn() async throws {
        let store = TestStore(
            initialState: Scan.State()
        ) {
            Scan()
        }

        store.dependencies.captureDevice = .noOp

        await store.send(.torchTapped) { state in
            state.isTorchOn = true
        }
        
        await store.finish()
    }

    func testTorchOff() async throws {
        let store = TestStore(
            initialState: Scan.State(
                isTorchOn: true
            )
        ) {
            Scan()
        }

        store.dependencies.captureDevice = .noOp

        await store.send(.torchTapped) { state in
            state.isTorchOn = false
        }
        
        await store.finish()
    }

    func testScannedInvalidValue() async throws {
        let store = TestStore(
            initialState: Scan.State()
        ) {
            Scan()
        }

        store.dependencies.uriParser.isValidURI = { _, _ in false }
        store.dependencies.mainQueue = .immediate
        
        let value = "test".redacted
        
        await store.send(.scan(value))
        
        await store.receive(.scanFailed(.invalidQRCode)) { state in
            state.info = String(localizable: .scanInvalidQR)
        }
        
        await store.receive(.clearInfo) { state in
            state.info = ""
        }

        await store.finish()
    }

    func testScannedValidAddress() async throws {
        let store = TestStore(
            initialState: Scan.State()
        ) {
            Scan()
        }
        
        store.dependencies.mainQueue = .immediate
        store.dependencies.uriParser.isValidURI = { _, _ in true }

        let address = "t1gXqfSSQt6WfpwyuCU3Wi7sSVZ66DYQ3Po".redacted
        
        await store.send(.scan(address))
        
        await store.receive(.found(address))
        
        await store.finish()
    }

    func testScanFailed() async throws {
        let store = TestStore(
            initialState: Scan.State()
        ) {
            Scan()
        }

        store.dependencies.mainQueue = .immediate

        await store.send(.scanFailed(.invalidQRCode)) { state in
            state.info = String(localizable: .scanInvalidQR)
        }
        
        await store.receive(.clearInfo) { state in
            state.info = ""
        }
        
        await store.finish()
    }
}
