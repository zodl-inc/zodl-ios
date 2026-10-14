import Testing
import ComposableArchitecture
@preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@MainActor
@Suite struct ServerSetupStoreTests {
    private final class Prefs: @unchecked Sendable {
        var automatic: Bool?
        var server: UserPreferencesStorage.ServerConfig?
    }

    @Test func manualSaveSwitchesPersistsAndFlagsManual() async {
        let prefs = Prefs()
        let switched = LockIsolated<LightWalletEndpoint?>(nil)

        var initial = ServerSetup.State()
        initial.connectionMode = .manual
        initial.initialConnectionMode = .automatic // a real change so hasChanges is true
        initial.selectedServer = "na.zec.rocks:443"
        initial.network = .mainnet

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.endpoint = {
                LightWalletEndpoint(address: "zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
            }
            $0.sdkSynchronizer.switchToEndpoint = { switched.setValue($0) }
            $0.userStoredPreferences.setAutomaticServerSelection = { prefs.automatic = $0 }
            $0.userStoredPreferences.setServer = { prefs.server = $0 }
            $0.transactionGuard = .testValue
        }
        store.exhaustivity = .off

        await store.send(.setServerTapped)
        await store.receive(\.switchSucceeded)

        #expect(switched.value?.host == "na.zec.rocks")
        #expect(prefs.automatic == false)
        #expect(prefs.server?.host == "na.zec.rocks")
        #expect(prefs.server?.isCustom == false)
    }

    @Test func automaticSaveFlagsAutomatic() async {
        let prefs = Prefs()

        var initial = ServerSetup.State()
        initial.connectionMode = .automatic
        initial.initialConnectionMode = .manual // a real change
        initial.topKServers = [ZcashSDKEnvironment.Server.hardcoded("na.zec.rocks:443")]   // recommendedSyncServer derives from topKServers.first
        initial.network = .mainnet

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.endpoint = {
                LightWalletEndpoint(address: "zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
            }
            $0.sdkSynchronizer.switchToEndpoint = { _ in }
            $0.sdkSynchronizer.evaluateBestOf = { _, _, _, _, _ in [] }
            $0.userStoredPreferences.setAutomaticServerSelection = { prefs.automatic = $0 }
            $0.userStoredPreferences.setServer = { prefs.server = $0 }
            $0.transactionGuard = .testValue
        }
        store.exhaustivity = .off

        await store.send(.setServerTapped)
        await store.receive(\.switchSucceeded)

        #expect(prefs.automatic == true)
        #expect(prefs.server?.host == "na.zec.rocks")
    }

    @Test func modeOnlyChangeSerializesThroughTransactionGuard() async throws {
        // Submission endpoints are read at submit time, so a connection-mode flip that lands
        // mid-submission changes where in-flight transactions fan out (e.g. a send pinned to a
        // private server fanning out to all public servers). A Save that needs no actual server
        // switch must still serialize the preference write through the transaction guard.
        let prefs = Prefs()
        let events = LockIsolated<[String]>([])
        let switched = LockIsolated(false)

        var initial = ServerSetup.State()
        initial.connectionMode = .automatic
        initial.initialConnectionMode = .manual // a real change so hasChanges is true
        initial.topKServers = [ZcashSDKEnvironment.Server.hardcoded("na.zec.rocks:443")]
        initial.network = .mainnet

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.endpoint = {
                // Same host and port as the recommended server: no switch is needed.
                LightWalletEndpoint(address: "na.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
            }
            $0.sdkSynchronizer.switchToEndpoint = { _ in switched.setValue(true) }
            $0.sdkSynchronizer.evaluateBestOf = { _, _, _, _, _ in [] }
            $0.userStoredPreferences.setAutomaticServerSelection = { value in
                prefs.automatic = value
                events.withValue { $0.append("setMode") }
            }
            $0.userStoredPreferences.setServer = { prefs.server = $0 }
            $0.transactionGuard = .testValue
            $0.transactionGuard.acquire = { events.withValue { $0.append("acquire") } }
            $0.transactionGuard.release = { events.withValue { $0.append("release") } }
        }
        store.exhaustivity = .off

        await store.send(.setServerTapped)
        await store.receive(\.switchSucceeded)

        #expect(!switched.value, "same host and port must not trigger an actual server switch")
        #expect(prefs.automatic == true)

        let order = events.withValue { $0 }
        let acquireIndex = try #require(order.firstIndex(of: "acquire"))
        let setModeIndex = try #require(order.firstIndex(of: "setMode"))
        let releaseIndex = try #require(order.lastIndex(of: "release"))
        #expect(acquireIndex < setModeIndex, "the mode flip must wait for the guard")
        #expect(setModeIndex < releaseIndex, "the mode flip must happen before the guard is released")
    }

    @Test func noChangesDoesNothing() async {
        let store = TestStore(initialState: ServerSetup.State()) {
            ServerSetup()
        } withDependencies: {
            $0.transactionGuard = .testValue
        }
        // connectionMode == initialConnectionMode and no selection -> hasChanges is false
        await store.send(.setServerTapped)
    }

    @Test func onAppearClearsStuckUpdatingFlag() async {
        var initial = ServerSetup.State()
        initial.isUpdatingServer = true   // a previous switch that hung or was cancelled left this set
        initial.network = .mainnet
        initial.topKServers = [.default]  // non-empty so onAppear doesn't kick off an evaluation

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.serverConfig = {
                UserPreferencesStorage.ServerConfig(host: "zec.rocks", port: 443, isCustom: false)
            }
            $0.userStoredPreferences.automaticServerSelection = { true }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)

        #expect(!store.state.isUpdatingServer, "onAppear must clear a stuck isUpdatingServer flag so the screen isn't wedged")
    }

    @Test func switchingToAutomaticBenchmarksWhenNoFreshResultAndOffersFastest() async {
        var initial = ServerSetup.State()
        initial.connectionMode = .manual
        initial.activeSyncServer = "na.zec.rocks:443" // current server, offered as a placeholder
        initial.network = .mainnet
        // topKServers empty -> switching to Automatic must benchmark

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.sdkSynchronizer.evaluateBestOf = { _, _, _, _, _ in
                [LightWalletEndpoint(address: "eu.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)]
            }
            $0.transactionGuard = .testValue
        }
        store.exhaustivity = .off

        // Before benchmarking, Automatic offers the current server as a placeholder.
        #expect(store.state.automaticDisplayServer == "na.zec.rocks:443")

        await store.send(.connectionModeChanged(.automatic))
        await store.receive(\.evaluateServers)
        await store.receive(\.evaluatedServers)

        // After benchmarking, Automatic offers the fastest server.
        #expect(store.state.recommendedSyncServer == "eu.zec.rocks:443")
        #expect(store.state.automaticDisplayServer == "eu.zec.rocks:443")
    }

    @Test func switchingToAutomaticReusesFreshBenchmark() async {
        let benchmarked = LockIsolated(false)

        var initial = ServerSetup.State()
        initial.connectionMode = .manual
        initial.activeSyncServer = "na.zec.rocks:443"
        initial.topKServers = [.hardcoded("eu.zec.rocks:443")] // a fresh result already exists
        initial.network = .mainnet

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.sdkSynchronizer.evaluateBestOf = { _, _, _, _, _ in
                benchmarked.setValue(true)
                return []
            }
            $0.transactionGuard = .testValue
        }
        store.exhaustivity = .off

        await store.send(.connectionModeChanged(.automatic))

        // No benchmark runs; Automatic immediately offers the existing fastest server.
        #expect(!benchmarked.value, "must not re-benchmark when a fresh result already exists")
        #expect(store.state.connectionMode == .automatic)
        #expect(store.state.automaticDisplayServer == "eu.zec.rocks:443")
    }
}
