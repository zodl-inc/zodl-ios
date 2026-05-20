//
//  SelectedServersMigrationTests.swift
//  secantTests
//
//  Created by Adam Tucker on 2026-04-05.
//

import XCTest
import ComposableArchitecture
import ZcashLightClientKit
@testable import secant_testnet

class SelectedServersMigrationTests: XCTestCase {

    // MARK: - Custom server user → manual mode

    func testCustomServerUser_migratesToManualMode() throws {
        let customServer = UserPreferencesStorage.ServerConfig(
            host: "my-custom-node.example.com",
            port: 9067,
            isCustom: true
        )

        try assertManualMigration(
            migratedSelectedServers(existingServer: customServer),
            server: customServer,
            isCustom: true
        )
    }

    func testLegacyInfraServerUser_migratesToManualMode() throws {
        let infraServer = UserPreferencesStorage.ServerConfig(
            host: "lwd1.zcash-infra.com",
            port: 443,
            isCustom: false
        )

        try assertManualMigration(
            migratedSelectedServers(existingServer: infraServer),
            server: infraServer,
            isCustom: true
        )
    }

    // MARK: - Default server user → automatic mode

    func testDefaultServerUser_migratesToAutomaticMode() throws {
        let defaultEndpoint = ZcashSDKEnvironment.defaultEndpoint(for: .mainnet)
        let defaultServer = UserPreferencesStorage.ServerConfig(
            host: defaultEndpoint.host,
            port: defaultEndpoint.port,
            isCustom: false
        )

        try assertAutomaticMigration(migratedSelectedServers(existingServer: defaultServer))
    }

    // MARK: - Non-default known server user → manual mode

    func testNonDefaultKnownServerUser_migratesToManualMode() throws {
        let knownServer = UserPreferencesStorage.ServerConfig(
            host: "zec.rocks",
            port: 443,
            isCustom: false
        )

        try assertManualMigration(
            migratedSelectedServers(existingServer: knownServer),
            server: knownServer,
            isCustom: false
        )
    }

    func testUnknownNonCustomServerUser_migratesToManualCustomMode() throws {
        let unknownServer = UserPreferencesStorage.ServerConfig(
            host: "previously-known.example.com",
            port: 443,
            isCustom: false
        )

        try assertManualMigration(
            migratedSelectedServers(existingServer: unknownServer),
            server: unknownServer,
            isCustom: true
        )
    }

    // MARK: - New user → automatic mode

    func testNewUser_defaultsToAutomaticMode() throws {
        try assertAutomaticMigration(migratedSelectedServers(existingServer: nil))
    }

    // MARK: - Already migrated user is not re-migrated

    func testAlreadyMigratedUser_noOp() {
        let existingConfig = UserPreferencesStorage.SelectedServersConfig(
            mode: .manual,
            servers: [.init(host: "zec.rocks", port: 443, isCustom: false)]
        )

        XCTAssertNil(
            migratedSelectedServers(existingServer: nil, existingSelectedServers: existingConfig),
            "Should not overwrite existing selectedServers config"
        )
    }

    func testManualSelectedServerOverridesLegacyServerConfig() {
        let manualServer = UserPreferencesStorage.ServerConfig(
            host: "manual.example.com",
            port: 9067,
            isCustom: true
        )
        let legacyServer = UserPreferencesStorage.ServerConfig(
            host: "old.example.com",
            port: 443,
            isCustom: false
        )

        withDependencies {
            $0.userStoredPreferences.server = { legacyServer }
            $0.userStoredPreferences.selectedServers = {
                UserPreferencesStorage.SelectedServersConfig(mode: .manual, servers: [manualServer])
            }
        } operation: {
            let result = ZcashSDKEnvironment.serverConfig(for: .mainnet)

            XCTAssertEqual(result, manualServer)
        }
    }

    func testAutomaticModeUsesLegacyServerConfig() {
        let legacyServer = UserPreferencesStorage.ServerConfig(
            host: "eu.zec.stardust.rest",
            port: 443,
            isCustom: false
        )

        withDependencies {
            $0.userStoredPreferences.server = { legacyServer }
            $0.userStoredPreferences.selectedServers = {
                UserPreferencesStorage.SelectedServersConfig(mode: .automatic, servers: [])
            }
        } operation: {
            let result = ZcashSDKEnvironment.serverConfig(for: .mainnet)

            XCTAssertEqual(result, legacyServer)
        }
    }

    func testIsKnownEndpoint_isNetworkAware() {
        let testnetEndpoint = ZcashSDKEnvironment.defaultEndpoint(for: .testnet)

        XCTAssertTrue(ZcashSDKEnvironment.isKnownEndpoint(host: "zec.rocks", port: 443, network: .mainnet))
        XCTAssertFalse(ZcashSDKEnvironment.isKnownEndpoint(host: "zec.rocks", port: 443, network: .testnet))
        XCTAssertTrue(
            ZcashSDKEnvironment.isKnownEndpoint(
                host: testnetEndpoint.host,
                port: testnetEndpoint.port,
                network: .testnet
            )
        )
    }

    private func migratedSelectedServers(
        existingServer: UserPreferencesStorage.ServerConfig?,
        existingSelectedServers: UserPreferencesStorage.SelectedServersConfig? = nil,
        network: NetworkType = .mainnet
    ) -> UserPreferencesStorage.SelectedServersConfig? {
        let capturedSelectedServers = UncheckedSendableBox<UserPreferencesStorage.SelectedServersConfig?>(nil)

        withDependencies {
            $0.userStoredPreferences.server = { existingServer }
            $0.userStoredPreferences.selectedServers = { existingSelectedServers }
            $0.userStoredPreferences.setSelectedServers = { config in
                capturedSelectedServers.value = config
            }
        } operation: {
            ZcashSDKEnvironment.initializeSelectedServersIfNeeded(for: network)
        }

        return capturedSelectedServers.value
    }

    private func assertAutomaticMigration(
        _ config: UserPreferencesStorage.SelectedServersConfig?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let result = try XCTUnwrap(
            config,
            "Migration should have persisted a selectedServers config",
            file: file,
            line: line
        )
        XCTAssertEqual(result.mode, .automatic, file: file, line: line)
        XCTAssertTrue(result.servers.isEmpty, "Automatic mode should have empty servers array", file: file, line: line)
    }

    private func assertManualMigration(
        _ config: UserPreferencesStorage.SelectedServersConfig?,
        server: UserPreferencesStorage.ServerConfig,
        isCustom: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let result = try XCTUnwrap(
            config,
            "Migration should have persisted a selectedServers config",
            file: file,
            line: line
        )
        XCTAssertEqual(result.mode, .manual, file: file, line: line)
        XCTAssertEqual(
            result.servers.count,
            1,
            "Manual mode should preserve the selected server",
            file: file,
            line: line
        )
        XCTAssertEqual(result.servers.first?.host, server.host, file: file, line: line)
        XCTAssertEqual(result.servers.first?.port, server.port, file: file, line: line)
        XCTAssertEqual(result.servers.first?.isCustom, isCustom, file: file, line: line)
    }
}

@MainActor
class ServerSetupChangeDetectionTests: XCTestCase {
    private var customLabel: String {
        String(localizable: .serverSetupCustom)
    }

    private func makeStore(
        connectionMode: UserPreferencesStorage.ConnectionMode = .automatic,
        customServer: String = "",
        isEvaluatingServers: Bool = false,
        serverEvaluationRequestID: Int = 0,
        selectedServer: String? = nil,
        topKServers: [ZcashSDKEnvironment.Server] = [.default]
    ) -> TestStore<ServerSetup.State, ServerSetup.Action> {
        TestStore(
            initialState: ServerSetup.State(
                connectionMode: connectionMode,
                customServer: customServer,
                isEvaluatingServers: isEvaluatingServers,
                serverEvaluationRequestID: serverEvaluationRequestID,
                selectedServer: selectedServer,
                topKServers: topKServers
            )
        ) {
            ServerSetup()
        }
    }

    private func makeEndpoint(address: String, port: Int = 443) -> LightWalletEndpoint {
        LightWalletEndpoint(
            address: address,
            port: port,
            secure: true,
            streamingCallTimeoutInMillis: ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis
        )
    }

    private func makeManualServer(host: String = "manual.example.com") -> UserPreferencesStorage.ServerConfig {
        .init(host: host, port: 9067, isCustom: true)
    }

    private func sendDefaultAutomaticEvaluation(
        _ store: TestStore<ServerSetup.State, ServerSetup.Action>,
        endpoint: LightWalletEndpoint
    ) async {
        await store.send(.evaluatedServers(0, [endpoint])) { state in
            state.isEvaluatingServers = false
            state.topKServers = [.default]
            state.servers = [.custom]
            state.recommendedSyncServer = endpoint.server()
        }
    }

    func testCustomServerEditMarksStateChangedWhenCustomIsSelected() async {
        let customServer = makeManualServer(host: "old-custom.example.com")

        let store = makeStore(connectionMode: .manual)

        store.dependencies.zcashSDKEnvironment = .testValue
        store.dependencies.userStoredPreferences.selectedServers = {
            UserPreferencesStorage.SelectedServersConfig(mode: .manual, servers: [customServer])
        }

        let originalValue = customServer.serverString()
        let updatedValue = "new-custom.example.com:9067"

        await store.send(.onAppear) { state in
            state.expectManualCustomSetup(server: originalValue)
        }

        XCTAssertFalse(store.state.hasChanges)

        await store.send(.binding(.set(\.customServer, updatedValue))) { state in
            state.customServer = updatedValue
        }

        XCTAssertTrue(store.state.hasChanges)
    }

    func testSwitchSucceededResetsChangeTracking() async {
        let customServer = makeManualServer(host: "old-custom.example.com")

        let store = makeStore(connectionMode: .manual)

        store.dependencies.zcashSDKEnvironment = .testValue
        store.dependencies.userStoredPreferences.selectedServers = {
            UserPreferencesStorage.SelectedServersConfig(mode: .manual, servers: [customServer])
        }

        let originalValue = customServer.serverString()
        let updatedValue = "new-custom.example.com:9067"

        await store.send(.onAppear) { state in
            state.expectManualCustomSetup(server: originalValue)
        }

        await store.send(.binding(.set(\.customServer, updatedValue))) { state in
            state.customServer = updatedValue
        }

        XCTAssertTrue(store.state.hasChanges)

        await store.send(.switchSucceeded(updatedValue)) { state in
            state.isUpdatingServer = false
            state.initialConnectionMode = .manual
            state.initialSelectedServer = customLabel
            state.initialCustomServer = updatedValue
            state.activeSyncServer = updatedValue
        }

        XCTAssertFalse(store.state.hasChanges)
    }

    func testConnectionModeChangeMarksStateChanged() async {
        let activeEndpoint = ZcashSDKEnvironment.defaultEndpoint(for: .testnet)
        let store = makeStore()

        store.dependencies.zcashSDKEnvironment = .testValue
        store.dependencies.userStoredPreferences.selectedServers = {
            UserPreferencesStorage.SelectedServersConfig(mode: .automatic, servers: [])
        }

        await store.send(.onAppear) { state in
            state.expectAutomaticSetup()
        }

        XCTAssertFalse(store.state.hasChanges)

        await store.send(.connectionModeChanged(.manual)) { state in
            state.connectionMode = .manual
            state.selectedServer = activeEndpoint.server()
        }

        XCTAssertTrue(store.state.hasChanges)
    }

    func testManualModePreselectsKnownActiveEndpoint() async {
        let activeEndpoint = makeEndpoint(address: "zec.rocks")
        let store = makeStore()
        store.dependencies.zcashSDKEnvironment = testEnvironment {
            activeEndpoint.serverConfig()
        }

        await store.send(.binding(.set(\.activeSyncServer, activeEndpoint.server()))) { state in
            state.activeSyncServer = activeEndpoint.server()
        }

        await store.send(.connectionModeChanged(.manual)) { state in
            state.connectionMode = .manual
            state.selectedServer = activeEndpoint.server()
        }

        XCTAssertTrue(store.state.hasChanges)
    }

    func testManualModePreselectsUnknownActiveEndpointAsCustom() async {
        let activeEndpoint = makeEndpoint(address: "custom.example.com", port: 9067)
        let store = makeStore()
        store.dependencies.zcashSDKEnvironment = testEnvironment {
            activeEndpoint.serverConfig(isCustom: true)
        }

        await store.send(.binding(.set(\.activeSyncServer, activeEndpoint.server()))) { state in
            state.activeSyncServer = activeEndpoint.server()
        }

        await store.send(.connectionModeChanged(.manual)) { state in
            state.connectionMode = .manual
            state.selectedServer = customLabel
            state.customServer = activeEndpoint.server()
        }

        XCTAssertTrue(store.state.hasChanges)
    }

    func testManualModeRefreshesActiveEndpointBeforePreselecting() async {
        let initialServer = ZcashSDKEnvironment.defaultEndpoint(for: .testnet).serverConfig()
        let latestServer = makeManualServer(host: "custom.example.com")
        let activeServer = UncheckedSendableBox(initialServer)
        let store = makeStore()

        store.dependencies.zcashSDKEnvironment = testEnvironment {
            activeServer.value
        }
        store.dependencies.userStoredPreferences.selectedServers = {
            UserPreferencesStorage.SelectedServersConfig(mode: .automatic, servers: [])
        }

        await store.send(.onAppear) { state in
            state.expectAutomaticSetup(activeServer: initialServer.serverString())
        }

        activeServer.value = latestServer

        await store.send(.connectionModeChanged(.manual)) { state in
            state.connectionMode = .manual
            state.activeSyncServer = latestServer.serverString()
            state.selectedServer = customLabel
            state.customServer = latestServer.serverString()
        }

        XCTAssertTrue(store.state.hasChanges)
    }

    func testManualModeWithMissingActiveEndpointRequiresSelection() async {
        let store = makeStore()

        await store.send(.connectionModeChanged(.manual)) { state in
            state.connectionMode = .manual
        }

        XCTAssertNil(store.state.selectedServer)
        XCTAssertTrue(store.state.connectionMode == .manual && store.state.selectedServer == nil)
    }

    func testSavingManualModeAfterAutomaticPinsActiveEndpoint() async throws {
        let activeEndpoint = ZcashSDKEnvironment.defaultEndpoint(for: .testnet)
        let capturedSelectedServers = UncheckedSendableBox<UserPreferencesStorage.SelectedServersConfig?>(nil)
        let capturedServer = UncheckedSendableBox<UserPreferencesStorage.ServerConfig?>(nil)
        let store = makeStore()

        store.dependencies.zcashSDKEnvironment = .testValue
        store.dependencies.mainQueue = .immediate
        store.dependencies.userStoredPreferences.selectedServers = {
            UserPreferencesStorage.SelectedServersConfig(mode: .automatic, servers: [])
        }
        store.dependencies.userStoredPreferences.setSelectedServers = { config in
            capturedSelectedServers.value = config
        }
        store.dependencies.userStoredPreferences.setServer = { config in
            capturedServer.value = config
        }

        await store.send(.onAppear) { state in
            state.expectAutomaticSetup(activeServer: activeEndpoint.server())
        }

        await store.send(.connectionModeChanged(.manual)) { state in
            state.connectionMode = .manual
            state.selectedServer = activeEndpoint.server()
        }

        await store.send(.setServerTapped) { state in
            state.isUpdatingServer = true
        }

        await store.receive(.switchSucceeded(activeEndpoint.server())) { state in
            state.isUpdatingServer = false
            state.initialConnectionMode = .manual
            state.initialSelectedServer = activeEndpoint.server()
            state.activeSyncServer = activeEndpoint.server()
        }

        let selectedServers = try XCTUnwrap(capturedSelectedServers.value)
        XCTAssertEqual(selectedServers.mode, .manual)
        XCTAssertEqual(selectedServers.servers.first?.host, activeEndpoint.host)
        XCTAssertEqual(selectedServers.servers.first?.port, activeEndpoint.port)
        XCTAssertEqual(capturedServer.value?.host, activeEndpoint.host)
        XCTAssertEqual(capturedServer.value?.port, activeEndpoint.port)
    }

    func testAutomaticSaveSurfacesPersistenceFailure() async {
        let manualServer = makeManualServer()
        let automaticEndpoint = ZcashSDKEnvironment.defaultEndpoint(for: .testnet)
        let persistenceError = UserPreferencesStorage.UserPreferencesStorageError.selectedServersConfig.toZcashError()
        let store = makeStore(connectionMode: .manual)

        store.dependencies.zcashSDKEnvironment = .testValue
        store.dependencies.mainQueue = .immediate
        store.dependencies.userStoredPreferences.selectedServers = {
            UserPreferencesStorage.SelectedServersConfig(mode: .manual, servers: [manualServer])
        }
        store.dependencies.userStoredPreferences.setSelectedServers = { _ in
            throw UserPreferencesStorage.UserPreferencesStorageError.selectedServersConfig
        }
        store.dependencies.sdkSynchronizer = .mocked(
            switchToEndpoint: { _ in }
        )

        await store.send(.onAppear) { state in
            state.expectManualCustomSetup(server: manualServer.serverString())
        }

        await store.send(.connectionModeChanged(.automatic)) { state in
            state.connectionMode = .automatic
        }

        await sendDefaultAutomaticEvaluation(store, endpoint: automaticEndpoint)

        await store.send(.setServerTapped) { state in
            state.isUpdatingServer = true
        }

        await store.receive(.switchFailed(persistenceError)) { state in
            state.isUpdatingServer = false
            state.alert = AlertState.endpointSwitchFailed(persistenceError)
        }
    }

    func testAutomaticSaveRollsBackEndpointWhenLegacyServerPersistenceFails() async {
        let manualServer = makeManualServer()
        let automaticEndpoint = ZcashSDKEnvironment.defaultEndpoint(for: .testnet)
        let persistenceError = UserPreferencesStorage.UserPreferencesStorageError.serverConfig.toZcashError()
        let activeServer = UncheckedSendableBox(manualServer)
        let storedSelectedServers = UncheckedSendableBox<UserPreferencesStorage.SelectedServersConfig?>(
            UserPreferencesStorage.SelectedServersConfig(mode: .manual, servers: [manualServer])
        )
        let switchedEndpoints = UncheckedSendableBox<[String]>([])
        let store = makeStore(connectionMode: .manual)

        store.dependencies.zcashSDKEnvironment = testEnvironment {
            activeServer.value
        }
        store.dependencies.mainQueue = .immediate
        store.dependencies.userStoredPreferences.selectedServers = {
            storedSelectedServers.value
        }
        store.dependencies.userStoredPreferences.setSelectedServers = { config in
            storedSelectedServers.value = config
        }
        store.dependencies.userStoredPreferences.setServer = { _ in
            throw UserPreferencesStorage.UserPreferencesStorageError.serverConfig
        }
        store.dependencies.sdkSynchronizer = .mocked(
            switchToEndpoint: { endpoint in
                switchedEndpoints.value.append(endpoint.server())
                activeServer.value = endpoint.serverConfig()
            }
        )

        await store.send(.onAppear) { state in
            state.expectManualCustomSetup(server: manualServer.serverString())
        }

        await store.send(.connectionModeChanged(.automatic)) { state in
            state.connectionMode = .automatic
        }

        await sendDefaultAutomaticEvaluation(store, endpoint: automaticEndpoint)

        await store.send(.setServerTapped) { state in
            state.isUpdatingServer = true
        }

        await store.receive(.switchFailed(persistenceError)) { state in
            state.isUpdatingServer = false
            state.alert = AlertState.endpointSwitchFailed(persistenceError)
        }

        XCTAssertEqual(switchedEndpoints.value, [automaticEndpoint.server(), manualServer.serverString()])
        XCTAssertEqual(storedSelectedServers.value?.mode, .manual)
        XCTAssertEqual(storedSelectedServers.value?.servers.first?.host, manualServer.host)
        XCTAssertEqual(storedSelectedServers.value?.servers.first?.port, manualServer.port)
        XCTAssertEqual(activeServer.value.host, manualServer.host)
        XCTAssertEqual(activeServer.value.port, manualServer.port)
    }

    func testAutomaticSaveClearsStaleManualSelectionBeforeManualPreselect() async {
        let manualServer = makeManualServer()
        let automaticEndpoint = ZcashSDKEnvironment.defaultEndpoint(for: .testnet)
        let automaticServer = automaticEndpoint.serverConfig()
        let activeServer = UncheckedSendableBox(manualServer)
        let storedSelectedServers = UncheckedSendableBox<UserPreferencesStorage.SelectedServersConfig?>(
            UserPreferencesStorage.SelectedServersConfig(mode: .manual, servers: [manualServer])
        )
        let storedServer = UncheckedSendableBox<UserPreferencesStorage.ServerConfig?>(manualServer)
        let store = makeStore(connectionMode: .manual)

        store.dependencies.zcashSDKEnvironment = testEnvironment {
            activeServer.value
        }
        store.dependencies.mainQueue = .immediate
        store.dependencies.userStoredPreferences.server = {
            storedServer.value
        }
        store.dependencies.userStoredPreferences.selectedServers = {
            storedSelectedServers.value
        }
        store.dependencies.userStoredPreferences.setServer = { config in
            storedServer.value = config
            activeServer.value = config
        }
        store.dependencies.userStoredPreferences.setSelectedServers = { config in
            storedSelectedServers.value = config
        }
        store.dependencies.sdkSynchronizer = .mocked(
            switchToEndpoint: { endpoint in
                activeServer.value = endpoint.serverConfig()
            }
        )

        await store.send(.onAppear) { state in
            state.expectManualCustomSetup(server: manualServer.serverString())
        }

        await store.send(.connectionModeChanged(.automatic)) { state in
            state.connectionMode = .automatic
        }

        await sendDefaultAutomaticEvaluation(store, endpoint: automaticEndpoint)

        await store.send(.setServerTapped) { state in
            state.isUpdatingServer = true
        }

        await store.receive(.switchSucceeded(automaticServer.serverString())) { state in
            state.isUpdatingServer = false
            state.customServer = ""
            state.initialConnectionMode = .automatic
            state.initialCustomServer = ""
            state.selectedServer = nil
            state.initialSelectedServer = nil
            state.activeSyncServer = automaticServer.serverString()
        }

        await store.send(.connectionModeChanged(.manual)) { state in
            state.connectionMode = .manual
            state.activeSyncServer = automaticServer.serverString()
            state.selectedServer = automaticServer.serverString()
        }

        XCTAssertTrue(store.state.hasChanges)
    }

    func testOnAppearClearsUnsavedManualSelectionWhenStoredModeIsAutomatic() async {
        let store = makeStore(
            connectionMode: .manual,
            customServer: "unsaved.example.com:9067",
            selectedServer: customLabel
        )

        store.dependencies.zcashSDKEnvironment = .testValue
        store.dependencies.userStoredPreferences.selectedServers = {
            UserPreferencesStorage.SelectedServersConfig(mode: .automatic, servers: [])
        }

        await store.send(.onAppear) { state in
            state.expectAutomaticSetup()
            state.customServer = ""
            state.initialCustomServer = ""
            state.selectedServer = nil
            state.initialSelectedServer = nil
        }

        XCTAssertFalse(store.state.hasChanges)
    }

    func testAutomaticEvaluationKeepsActiveSyncServerTruthful() async {
        let store = makeStore()

        store.dependencies.zcashSDKEnvironment = .testValue

        await store.send(.onAppear) { state in
            state.expectAutomaticSetup()
        }

        let evaluatedEndpoint = makeEndpoint(address: "faster.example.com")

        await store.send(.evaluatedServers(0, [evaluatedEndpoint])) { state in
            state.isEvaluatingServers = false
            state.topKServers = [.hardcoded("faster.example.com:443")]
            state.servers = [.default, .custom]
            state.recommendedSyncServer = "faster.example.com:443"
        }

        XCTAssertEqual(
            store.state.activeSyncServer,
            ZcashSDKEnvironment.defaultEndpoint(for: .testnet).server(),
            "Benchmarking should not relabel the active sync endpoint before an actual switch"
        )
        XCTAssertEqual(store.state.recommendedSyncServer, "faster.example.com:443")
    }

    func testStaleEvaluatedServersResultIsIgnored() async {
        let store = makeStore(
            isEvaluatingServers: true,
            serverEvaluationRequestID: 2,
            topKServers: []
        )

        store.dependencies.zcashSDKEnvironment = .testValue

        let staleEndpoint = makeEndpoint(address: "stale.example.com")

        await store.send(.evaluatedServers(1, [staleEndpoint]))

        XCTAssertTrue(store.state.isEvaluatingServers, "Older evaluation should not finish the latest request")
        XCTAssertTrue(store.state.topKServers.isEmpty, "Stale evaluation results should be ignored")
        XCTAssertNil(store.state.recommendedSyncServer, "Ignored stale results should not update recommendations")
    }

    private func testEnvironment(
        serverConfig: @escaping @Sendable () -> UserPreferencesStorage.ServerConfig
    ) -> ZcashSDKEnvironment {
        ZcashSDKEnvironment(
            latestCheckpoint: 0,
            endpoint: {
                serverConfig().endpoint(
                    streamingCallTimeoutInMillis: ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis
                )
            },
            exchangeRateIPRateLimit: 120,
            exchangeRateStaleLimit: 15 * 60,
            memoCharLimit: MemoBytes.capacity,
            mnemonicWordsMaxCount: ZcashSDKEnvironment.ZcashSDKConstants.mnemonicWordsMaxCount,
            network: ZcashNetworkBuilder.network(for: .testnet),
            requiredTransactionConfirmations: ZcashSDKEnvironment.ZcashSDKConstants.requiredTransactionConfirmations,
            sdkVersion: "test",
            serverConfig: serverConfig,
            servers: ZcashSDKEnvironment.servers(for: .testnet),
            shieldingThreshold: Zatoshi(100_000),
            tokenName: "TAZ"
        )
    }
}

private extension ServerSetup.State {
    mutating func expectAutomaticSetup(
        activeServer: String = ZcashSDKEnvironment.defaultEndpoint(for: .testnet).server()
    ) {
        network = .testnet
        activeSyncServer = activeServer
        connectionMode = .automatic
        initialConnectionMode = .automatic
        servers = [.custom]
    }

    mutating func expectManualCustomSetup(server: String) {
        let customLabel = String(localizable: .serverSetupCustom)
        network = .testnet
        activeSyncServer = server
        customServer = server
        initialCustomServer = server
        connectionMode = .manual
        initialConnectionMode = .manual
        selectedServer = customLabel
        initialSelectedServer = customLabel
        servers = [.custom]
    }
}
