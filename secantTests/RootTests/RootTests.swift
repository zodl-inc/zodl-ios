//
//  RootTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 12.04.2022.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

@MainActor
class RootTests: XCTestCase {
    func testWalletInitializationState_Uninitialized() throws {
        let walletState = Root.walletInitializationState(
            databaseFiles: .noOp,
            walletStorage: .noOp,
            zcashNetwork: ZcashNetworkBuilder.network(for: .testnet)
        )

        XCTAssertEqual(walletState, .uninitialized)
    }

    func testWalletInitializationState_FilesPresentKeysMissing() throws {
        let wfmMock = FileManagerClient(
            url: { _, _, _, _ in .emptyURL },
            fileExists: { _ in return true },
            removeItem: { _ in }
        )

        let walletState = Root.walletInitializationState(
            databaseFiles: .live(databaseFiles: DatabaseFiles(fileManager: wfmMock)),
            walletStorage: .noOp,
            zcashNetwork: ZcashNetworkBuilder.network(for: .testnet)
        )

        XCTAssertEqual(walletState, .keysMissing)
    }

    func testWalletInitializationState_FilesMissingKeysMissing() throws {
        let wfmMock = FileManagerClient(
            url: { _, _, _, _ in .emptyURL },
            fileExists: { _ in return false },
            removeItem: { _ in }
        )

        let walletState = Root.walletInitializationState(
            databaseFiles: .live(databaseFiles: DatabaseFiles(fileManager: wfmMock)),
            walletStorage: .noOp,
            zcashNetwork: ZcashNetworkBuilder.network(for: .testnet)
        )

        XCTAssertEqual(walletState, .uninitialized)
    }
    
    func testWalletInitializationState_FilesMissing() throws {
        let wfmMock = FileManagerClient(
            url: { _, _, _, _ in .emptyURL },
            fileExists: { _ in return false },
            removeItem: { _ in }
        )

        var walletStorage = WalletStorageClient.noOp
        walletStorage.areKeysPresent = { true }
        
        let walletState = Root.walletInitializationState(
            databaseFiles: .live(databaseFiles: DatabaseFiles(fileManager: wfmMock)),
            walletStorage: walletStorage,
            zcashNetwork: ZcashNetworkBuilder.network(for: .testnet)
        )

        XCTAssertEqual(walletState, .filesMissing)
    }
    
    func testWalletInitializationState_Initialized() throws {
        let wfmMock = FileManagerClient(
            url: { _, _, _, _ in .emptyURL },
            fileExists: { _ in return true },
            removeItem: { _ in }
        )

        var walletStorage = WalletStorageClient.noOp
        walletStorage.areKeysPresent = { true }
        
        let walletState = Root.walletInitializationState(
            databaseFiles: .live(databaseFiles: DatabaseFiles(fileManager: wfmMock)),
            walletStorage: walletStorage,
            zcashNetwork: ZcashNetworkBuilder.network(for: .testnet)
        )

        XCTAssertEqual(walletState, .initialized)
    }

    @MainActor func testRespondToWalletInitializationState_Uninitialized() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }

        store.dependencies.mainQueue = .immediate
        store.dependencies.walletStorage = .noOp
        store.dependencies.databaseFiles = .noOp

        await store.send(.initialization(.respondToWalletInitializationState(.uninitialized)))

        await store.receive(.destination(.updateDestination(.onboarding))) { state in
            state.destinationState.destination = .onboarding
            state.appInitializationState = .uninitialized
        }
        
        await store.finish()
    }

    func testRespondToWalletInitializationState_KeysMissing() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }

        store.dependencies.mainQueue = .immediate
        store.dependencies.walletStorage = .noOp
        store.dependencies.databaseFiles = .noOp

        await store.send(.initialization(.respondToWalletInitializationState(.keysMissing))) { state in
            state.appInitializationState = .keysMissing
        }
        
        await store.receive(.destination(.updateDestination(.onboarding))) { state in
            state.destinationState.internalDestination = .onboarding
            state.destinationState.previousDestination = .welcome
        }
        
        await store.finish()
    }

    func testRespondToWalletInitializationState_FilesMissing() async throws {
        let walletStorageError: Error = "export failed"
        let zcashError = ZcashError.unknown(walletStorageError)

        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        
        store.dependencies.walletStorage = .noOp
        store.dependencies.walletStorage.exportWallet = { throw zcashError }

        await store.send(.initialization(.respondToWalletInitializationState(.filesMissing))) { state in
            state.appInitializationState = .filesMissing
            state.isRestoringWallet = true
        }
        
        await store.receive(.initialization(.initializeSDK(.restoreWallet)))

        await store.receive(.initialization(.checkBackupPhraseValidation))

        await store.receive(.initialization(.initializationFailed(zcashError))) { state in
            state.appInitializationState = .failed
            state.alert = AlertState.initializationFailed(zcashError)
        }
        
        await store.receive(.initialization(.initializationFailed(zcashError)))
        
        await store.finish()
    }

    func testRespondToWalletInitializationState_Initialized() async throws {
        let walletStorageError: Error = "export failed"
        let zcashError = ZcashError.unknown(walletStorageError)

        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        
        store.dependencies.walletStorage = .noOp
        store.dependencies.walletStorage.exportWallet = { throw walletStorageError }
        store.dependencies.userDefaults = .noOp

        await store.send(.initialization(.respondToWalletInitializationState(.initialized)))

        await store.receive(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(.initialization(.checkBackupPhraseValidation))
        
        await store.receive(.initialization(.initializationFailed(zcashError))) { state in
            state.appInitializationState = .failed
            state.alert = AlertState.initializationFailed(zcashError)
        }
        
        await store.receive(.initialization(.initializationFailed(zcashError)))

        await store.finish()
    }
}
