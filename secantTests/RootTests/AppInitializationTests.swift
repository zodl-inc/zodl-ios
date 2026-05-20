//
//  AppInitializationTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 31.05.2022.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

class AppInitializationTests: XCTestCase {
    @MainActor func testForegroundBenchmarkGateRunsBenchmark() async throws {
        var appState = Root.State.initial
        appState.appStartState = .willEnterForeground

        let store = TestStore(
            initialState: appState
        ) {
            Root()
        }

        store.dependencies.userStoredPreferences.selectedServers = { nil }

        await store.send(.benchmarkSyncEndpointIfForeground)

        await store.receive(.benchmarkSyncEndpoint)

        await store.finish()
    }

    @MainActor func testBackgroundedForegroundRestartDoesNotBenchmarkEndpoint() async throws {
        var appState = Root.State.initial
        appState.appStartState = .didEnterBackground

        let store = TestStore(
            initialState: appState
        ) {
            Root()
        }

        await store.send(.benchmarkSyncEndpointIfForeground)

        await store.finish()
    }

    @MainActor func testCompletedAutomaticBenchmarkAppliesLatestEndpoint() async throws {
        var appState = Root.State.initial
        appState.appStartState = .willEnterForeground

        let bestEndpoint = LightWalletEndpoint(
            address: "faster.example.com",
            port: 443,
            secure: true,
            streamingCallTimeoutInMillis: ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis
        )
        let storedServer = UncheckedSendableBox<UserPreferencesStorage.ServerConfig?>(nil)
        let switchedEndpoints = UncheckedSendableBox<[String]>([])

        let store = TestStore(
            initialState: appState
        ) {
            Root()
        }

        store.dependencies.zcashSDKEnvironment = .testValue
        store.dependencies.userStoredPreferences.selectedServers = {
            UserPreferencesStorage.SelectedServersConfig(mode: .automatic, servers: [])
        }
        store.dependencies.userStoredPreferences.setServer = { config in
            storedServer.value = config
        }
        store.dependencies.sdkSynchronizer = .mocked(
            switchToEndpoint: { endpoint in
                switchedEndpoints.value.append(endpoint.server())
            }
        )

        await store.send(.automaticEndpointRefreshEvaluated(bestEndpoint))

        await store.receive(.serverSetup(.automaticEndpointUpdated(bestEndpoint.server()))) { state in
            state.serverSetupState.activeSyncServer = bestEndpoint.server()
        }

        XCTAssertEqual(switchedEndpoints.value, [bestEndpoint.server()])
        XCTAssertEqual(storedServer.value?.host, bestEndpoint.host)
        XCTAssertEqual(storedServer.value?.port, bestEndpoint.port)

        await store.finish()
    }

    @MainActor func testCompletedAutomaticBenchmarkDoesNotApplyWhenBackgrounded() async throws {
        var appState = Root.State.initial
        appState.appStartState = .didEnterBackground

        let bestEndpoint = LightWalletEndpoint(
            address: "faster.example.com",
            port: 443,
            secure: true,
            streamingCallTimeoutInMillis: ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis
        )

        let store = TestStore(
            initialState: appState
        ) {
            Root()
        }

        await store.send(.automaticEndpointRefreshEvaluated(bestEndpoint))

        await store.finish()
    }

    @MainActor func testCompletedAutomaticBenchmarkDoesNotApplyInManualMode() async throws {
        var appState = Root.State.initial
        appState.appStartState = .willEnterForeground

        let bestEndpoint = LightWalletEndpoint(
            address: "faster.example.com",
            port: 443,
            secure: true,
            streamingCallTimeoutInMillis: ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis
        )
        let switchedEndpoints = UncheckedSendableBox<[String]>([])
        let storedServer = UncheckedSendableBox<UserPreferencesStorage.ServerConfig?>(nil)

        let store = TestStore(
            initialState: appState
        ) {
            Root()
        }

        store.dependencies.userStoredPreferences.selectedServers = {
            UserPreferencesStorage.SelectedServersConfig(
                mode: .manual,
                servers: [
                    UserPreferencesStorage.ServerConfig(host: "manual.example.com", port: 9067, isCustom: true)
                ]
            )
        }
        store.dependencies.userStoredPreferences.setServer = { config in
            storedServer.value = config
        }
        store.dependencies.sdkSynchronizer = .mocked(
            switchToEndpoint: { endpoint in
                switchedEndpoints.value.append(endpoint.server())
            }
        )

        await store.send(.automaticEndpointRefreshEvaluated(bestEndpoint))

        XCTAssertTrue(switchedEndpoints.value.isEmpty)
        XCTAssertNil(storedServer.value)

        await store.finish()
    }

    /// This integration test starts with finishing the app launch and triggering bunch of initialization procedures.
    @MainActor func testDidFinishLaunching_to_InitializedWallet() async throws {
        var defaultRawFlags = WalletConfig.initial.flags
        defaultRawFlags[.testBackupPhraseFlow] = true
        let walletConfig = WalletConfig(flags: defaultRawFlags)

        var appState = Root.State.initial
        appState.walletConfig = walletConfig

        let store = TestStore(
            initialState: appState
        ) {
            Root()
        }
        
        let testQueue = DispatchQueue.test

        let storedWallet = StoredWallet(
            language: .english,
            seedPhrase: SeedPhrase(RecoveryPhrase.testPhrase.joined(separator: " ")),
            version: 0,
            birthday: Birthday(0),
            hasUserPassedPhraseBackupTest: true
        )
        
        store.dependencies.databaseFiles = .noOp
        store.dependencies.databaseFiles.areDbFilesPresentFor = { _ in true }
        store.dependencies.derivationTool = .liveValue
        store.dependencies.diskSpaceChecker = .mockEmptyDisk
        store.dependencies.mainQueue = .immediate
        store.dependencies.mnemonic = .mock
        store.dependencies.walletStorage.exportWallet = { storedWallet }
        store.dependencies.walletStorage.areKeysPresent = { true }
        store.dependencies.walletConfigProvider = .noOp
        store.dependencies.sdkSynchronizer = .noOp
        store.dependencies.numberFormatter = .noOp
        store.dependencies.userDefaults = .noOp
        store.dependencies.autolockHandler = .noOp
        store.dependencies.exchangeRate = .noOp

        // Root of the test, the app finished the launch process and triggers the checks and initializations.
        await store.send(.initialization(.appDelegate(.didFinishLaunching))) { state in
            state.appStartState = .didFinishLaunching
        }

        await testQueue.advance(by: 0.02)

        await store.receive(.initialization(.initialSetups))

        await testQueue.advance(by: 0.02)

        await store.receive(.initialization(.checkWalletInitialization))

        await store.receive(.initialization(.respondToWalletInitializationState(.initialized)))

        await testQueue.advance(by: 3.00)

        await store.receive(.initialization(.initializeSDK(.existingWallet)))

        await store.receive(.initialization(.checkBackupPhraseValidation)) { state in
            state.appInitializationState = .initialized
        }
        
        await store.receive(.initialization(.initializationSuccessfullyDone(nil)))

        await store.receive(.initialization(.registerForSynchronizersUpdate))

//        await store.receive(.tabs(.home(.transactionList(.onAppear)))) { state in
//            state.tabsState.homeState.transactionListState.requiredTransactionConfirmations = 10
//        }

        await store.receive(.destination(.updateDestination(.home))) { state in
            state.destinationState.previousDestination = .welcome
            state.destinationState.internalDestination = .home
        }

//        await store.receive(.tabs(.home(.transactionList(.updateTransactionList([])))))

        await store.send(.cancelAllRunningEffects)

        await store.finish()
    }
    
    @MainActor func testDidFinishLaunching_AwaitingPhraseConfirmation() async throws {
        var defaultRawFlags = WalletConfig.initial.flags
        defaultRawFlags[.testBackupPhraseFlow] = true
        let walletConfig = WalletConfig(flags: defaultRawFlags)

        var appState = Root.State.initial
        appState.walletConfig = walletConfig

        let store = TestStore(
            initialState: appState
        ) {
            Root()
        }
        
        let testQueue = DispatchQueue.test

        let storedWallet = StoredWallet(
            language: .english,
            seedPhrase: SeedPhrase(RecoveryPhrase.testPhrase.joined(separator: " ")),
            version: 0,
            birthday: Birthday(300_000),
            hasUserPassedPhraseBackupTest: false
        )
        
        store.dependencies.databaseFiles = .noOp
        store.dependencies.databaseFiles.areDbFilesPresentFor = { _ in true }
        store.dependencies.derivationTool = .liveValue
        store.dependencies.diskSpaceChecker = .mockEmptyDisk
        store.dependencies.mainQueue = .immediate
        store.dependencies.mnemonic = .mock
        store.dependencies.walletStorage.exportWallet = { storedWallet }
        store.dependencies.walletStorage.areKeysPresent = { true }
        store.dependencies.walletConfigProvider = .noOp
        store.dependencies.sdkSynchronizer = .noOp
        store.dependencies.numberFormatter = .noOp
        store.dependencies.userDefaults = .noOp
        store.dependencies.autolockHandler = .noOp
        store.dependencies.exchangeRate = .noOp

        // Root of the test, the app finished the launch process and triggers the checks and initializations.
        await store.send(.initialization(.appDelegate(.didFinishLaunching))) { state in
            state.appStartState = .didFinishLaunching
        }

        await testQueue.advance(by: 0.02)

        await store.receive(.initialization(.initialSetups))

        await testQueue.advance(by: 0.02)

        await store.receive(.initialization(.checkWalletInitialization))

        await store.receive(.initialization(.respondToWalletInitializationState(.initialized)))

        await testQueue.advance(by: 3.00)

        await store.receive(.initialization(.initializeSDK(.existingWallet)))

        let recoveryPhrase = RecoveryPhrase(words: try store.dependencies.mnemonic.randomMnemonicWords().map { $0.redacted })

        await store.receive(.initialization(.checkBackupPhraseValidation)) { state in
            state.appInitializationState = .initialized
            state.phraseDisplayState.phrase = recoveryPhrase
            state.phraseDisplayState.birthdayValue = ""
            state.phraseDisplayState.birthday = Birthday(300_000)
        }
        
        await store.receive(.initialization(.initializationSuccessfullyDone(nil)))

        await store.receive(.initialization(.registerForSynchronizersUpdate))

        await store.receive(.destination(.updateDestination(.phraseDisplay))) { state in
            state.destinationState.previousDestination = .welcome
            state.destinationState.internalDestination = .phraseDisplay
        }

        await store.send(.cancelAllRunningEffects)

        await store.finish()
    }
    
    /// Integration test validating the side effects work together properly when no wallet is stored but database files are present.
    @MainActor func testDidFinishLaunching_to_KeysMissing() async throws {
        let initialState = Root.State.initial
        
        let store = TestStore(
            initialState: initialState
        ) {
            Root()
        }

        store.dependencies.databaseFiles = .noOp
        store.dependencies.databaseFiles.areDbFilesPresentFor = { _ in true }
        store.dependencies.diskSpaceChecker = .mockEmptyDisk
        store.dependencies.walletStorage = .noOp
        store.dependencies.mainQueue = .immediate
        store.dependencies.walletConfigProvider = .noOp

        // Root of the test, the app finished the launch process and triggers the checks and initializations.
        await store.send(.initialization(.appDelegate(.didFinishLaunching))) { state in
            state.appStartState = .didFinishLaunching
        }

        await store.receive(.initialization(.initialSetups))

        await store.receive(.initialization(.checkWalletInitialization))

        await store.receive(.initialization(.respondToWalletInitializationState(.keysMissing))) { state in
            state.appInitializationState = .keysMissing
        }
        
        await store.receive(.destination(.updateDestination(.onboarding))) { state in
            state.destinationState.internalDestination = .onboarding
            state.destinationState.previousDestination = .welcome
        }
        
        await store.finish()
    }

    /// Integration test validating the side effects work together properly when no wallet is stored and no database files are present.
    @MainActor func testDidFinishLaunching_to_Uninitialized() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        
        store.dependencies.databaseFiles = .noOp
        store.dependencies.diskSpaceChecker = .mockEmptyDisk
        store.dependencies.mainQueue = .immediate
        store.dependencies.walletStorage = .noOp
        store.dependencies.walletConfigProvider = .noOp

        // Root of the test, the app finished the launch process and triggers the checks and initializations.
        await store.send(.initialization(.appDelegate(.didFinishLaunching))) { state in
            state.appStartState = .didFinishLaunching
        }

        await store.receive(.initialization(.initialSetups))

        await store.receive(.initialization(.checkWalletInitialization))

        await store.receive(.initialization(.respondToWalletInitializationState(.uninitialized)))
        
        await store.receive(.destination(.updateDestination(.onboarding))) { state in
            state.destinationState.previousDestination = .welcome
            state.destinationState.internalDestination = .onboarding
        }
        
        await store.finish()
    }
}
