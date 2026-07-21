import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
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
            // MOB-1496 (W4): no active migration snapshots -> the manual-switch privacy warning
            // never applies.
            $0.migrationManager.activeNetworkSnapshots = { [] }
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
            // R8-T7 (#10): the automatic Save path now reads migration pinning too -> no active
            // snapshots -> the filter is a no-op (byte-identical to pre-fix behavior).
            $0.migrationManager.activeNetworkSnapshots = { [] }
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
            // R8-T7 (#10): the automatic Save path now reads migration pinning too -> no active
            // snapshots -> the filter is a no-op (byte-identical to pre-fix behavior).
            $0.migrationManager.activeNetworkSnapshots = { [] }
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

    // MARK: - MOB-1496 (R8-T7 #10): automatic Save migration pinning
    //
    // Companion to `AutoServerSelectionPinningTests.swift`'s coverage of the SAME
    // `MigrationServerPinning.isCandidateAllowed` predicate, applied here to the Settings "Save"
    // (automatic mode) path instead of the background auto-selection loop -- pre-fix, this path
    // consulted no pinning at all (unlike `AutoServerSelectionLiveKey`, which already filtered).

    @Test func automaticSaveWithActiveSnapshotFiltersTheFreshBenchmarkAwayFromTheBroadcastProvider() async {
        // #10-a: active snapshot (broadcast provider = stardust) + automatic Save with a fresh
        // benchmark (no cached recommendation) -> the applied endpoint is never on that provider.
        let prefs = Prefs()
        let capturedCandidates = LockIsolated<[LightWalletEndpoint]>([])
        let active = snapshot(syncHost: "na.zec.rocks", broadcastHost: "us.zec.stardust.rest")

        var initial = ServerSetup.State()
        initial.connectionMode = .automatic
        initial.initialConnectionMode = .manual // a real change so hasChanges is true
        initial.network = .mainnet
        // topKServers empty -> no cached recommendation -> forces the fresh-benchmark branch.

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.endpoint = {
                LightWalletEndpoint(address: "na.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
            }
            $0.sdkSynchronizer.switchToEndpoint = { _ in }
            $0.sdkSynchronizer.evaluateBestOf = { candidates, _, _, _, _ in
                capturedCandidates.setValue(candidates)
                return [LightWalletEndpoint(address: "eu.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)]
            }
            $0.userStoredPreferences.setAutomaticServerSelection = { prefs.automatic = $0 }
            $0.userStoredPreferences.setServer = { prefs.server = $0 }
            $0.transactionGuard = .testValue
            $0.migrationManager.activeNetworkSnapshots = { [active] }
        }
        store.exhaustivity = .off

        await store.send(.setServerTapped)
        await store.receive(\.switchSucceeded)

        // Only the zecRocks family reached the benchmark -- the stardust family (incl. the
        // snapshot's OWN broadcast provider) never does.
        let candidateHosts = Set(capturedCandidates.value.map(\.host))
        #expect(candidateHosts == Set(["zec.rocks", "na.zec.rocks", "sa.zec.rocks", "eu.zec.rocks", "ap.zec.rocks"]))
        #expect(prefs.server?.host == "eu.zec.rocks")
    }

    @Test func automaticSaveDiscardsACachedRecommendationOnTheBroadcastProviderAndFallsBackToAFreshFilteredBenchmark() async {
        // #10-b: a cached recommendation sitting on the broadcast provider must not be applied --
        // it's discarded and a fresh FILTERED benchmark runs in its place.
        let prefs = Prefs()
        let evaluateBestOfCalls = LockIsolated<Int>(0)
        let capturedCandidates = LockIsolated<[LightWalletEndpoint]>([])
        let active = snapshot(syncHost: "na.zec.rocks", broadcastHost: "us.zec.stardust.rest")

        var initial = ServerSetup.State()
        initial.connectionMode = .automatic
        initial.initialConnectionMode = .manual
        // The cached recommendation (topKServers.first) IS the snapshot's own broadcast provider.
        initial.topKServers = [ZcashSDKEnvironment.Server.hardcoded("us.zec.stardust.rest:443")]
        initial.network = .mainnet

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.endpoint = {
                LightWalletEndpoint(address: "na.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
            }
            $0.sdkSynchronizer.switchToEndpoint = { _ in }
            $0.sdkSynchronizer.evaluateBestOf = { candidates, _, _, _, _ in
                evaluateBestOfCalls.withValue { $0 += 1 }
                capturedCandidates.setValue(candidates)
                return [LightWalletEndpoint(address: "eu.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)]
            }
            $0.userStoredPreferences.setAutomaticServerSelection = { prefs.automatic = $0 }
            $0.userStoredPreferences.setServer = { prefs.server = $0 }
            $0.transactionGuard = .testValue
            $0.migrationManager.activeNetworkSnapshots = { [active] }
        }
        store.exhaustivity = .off

        await store.send(.setServerTapped)
        await store.receive(\.switchSucceeded)

        #expect(evaluateBestOfCalls.value == 1, "the filtered-out cached recommendation must trigger a fresh benchmark")
        #expect(!capturedCandidates.value.map(\.host).contains("us.zec.stardust.rest"))
        #expect(prefs.server?.host == "eu.zec.rocks", "must never apply the cached recommendation's broadcast-provider host")
    }

    @Test func automaticSaveWithNoActiveSnapshotsBenchmarksTheFullUnfilteredCandidateList() async {
        // #10-c: no active snapshots -> behavior unchanged (byte-identical to pre-fix): every
        // built-in mainnet endpoint still reaches the benchmark, exactly like
        // `AutoServerSelectionPinningTests.findBestServerWithNoActiveSnapshotsIsUnfiltered`.
        let prefs = Prefs()
        let capturedCandidates = LockIsolated<[LightWalletEndpoint]>([])

        var initial = ServerSetup.State()
        initial.connectionMode = .automatic
        initial.initialConnectionMode = .manual
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
            $0.sdkSynchronizer.evaluateBestOf = { candidates, _, _, _, _ in
                capturedCandidates.setValue(candidates)
                return [LightWalletEndpoint(address: "na.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)]
            }
            $0.userStoredPreferences.setAutomaticServerSelection = { prefs.automatic = $0 }
            $0.userStoredPreferences.setServer = { prefs.server = $0 }
            $0.transactionGuard = .testValue
            $0.migrationManager.activeNetworkSnapshots = { [] }
        }
        store.exhaustivity = .off

        await store.send(.setServerTapped)
        await store.receive(\.switchSucceeded)

        #expect(Set(capturedCandidates.value.map(\.host)) == Set([
            "zec.rocks", "na.zec.rocks", "sa.zec.rocks", "eu.zec.rocks", "ap.zec.rocks",
            "us.zec.stardust.rest", "eu.zec.stardust.rest"
        ]))
        #expect(prefs.server?.host == "na.zec.rocks")
    }

    @Test func automaticSaveWithPinningLeavingNoCandidatesSkipsTheBenchmarkAndKeepsTheCurrentServer() async {
        // #10-d: empty-after-filter mirrors `AutoServerSelectionLiveKey.findBestServer`'s "skip the
        // round entirely" behavior -- a fully custom-family snapshot means no built-in mainnet host
        // ever classifies into it, so filtering empties the whole candidate list (mirrors
        // `AutoServerSelectionPinningTests.findBestServerSkipsTheRoundEntirelyWhenPinningLeavesNoCandidates`).
        // The benchmark must never run, and Save falls back to the CURRENT active endpoint (a no-op
        // pick) rather than an unfiltered default -- while the automatic-mode flip Save promised
        // still commits.
        let prefs = Prefs()
        let evaluateBestOfCalls = LockIsolated<Int>(0)
        let switched = LockIsolated<LightWalletEndpoint?>(nil)
        let active = snapshot(syncHost: "myserver.example.com", broadcastHost: "myserver.example.com")

        var initial = ServerSetup.State()
        initial.connectionMode = .automatic
        initial.initialConnectionMode = .manual
        initial.network = .mainnet

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.endpoint = {
                LightWalletEndpoint(address: "na.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
            }
            $0.sdkSynchronizer.switchToEndpoint = { switched.setValue($0) }
            $0.sdkSynchronizer.evaluateBestOf = { _, _, _, _, _ in
                evaluateBestOfCalls.withValue { $0 += 1 }
                return [LightWalletEndpoint(address: "eu.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)]
            }
            $0.userStoredPreferences.setAutomaticServerSelection = { prefs.automatic = $0 }
            $0.userStoredPreferences.setServer = { prefs.server = $0 }
            $0.transactionGuard = .testValue
            $0.migrationManager.activeNetworkSnapshots = { [active] }
        }
        store.exhaustivity = .off

        await store.send(.setServerTapped)
        await store.receive(\.switchSucceeded)

        #expect(evaluateBestOfCalls.value == 0, "the benchmark must never run once pinning empties the candidate set")
        #expect(switched.value == nil, "no endpoint switch -- the current server IS the mirrored fallback")
        #expect(prefs.automatic == true, "the mode flip Save promised must still commit")
        #expect(prefs.server?.host == "na.zec.rocks", "falls back to the CURRENT active endpoint, never an unpinned pick")
    }

    // MARK: - MOB-1496 (W4): manual-switch privacy warning

    private func snapshot(syncHost: String, broadcastHost: String) -> MigrationNetworkSnapshot {
        MigrationNetworkSnapshot(
            useTor: false,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: syncHost, port: 443, secure: true),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: broadcastHost, port: 443, secure: true),
            takenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: shouldWarnBeforeManualSwitch — pure predicate

    @Test func shouldWarnTriggersOnBroadcastProviderMatch() {
        let active = snapshot(syncHost: "na.zec.rocks", broadcastHost: "us.zec.stardust.rest")
        // Different literal host, SAME family (stardust) as the snapshot's broadcast provider.
        let chosen = LightWalletEndpoint(address: "eu.zec.stardust.rest", port: 443, secure: true, streamingCallTimeoutInMillis: 0)

        #expect(ServerSetup.shouldWarnBeforeManualSwitch(endpoint: chosen, activeSnapshots: [active]) == true)
    }

    @Test func shouldWarnTriggersOnBroadcastHostMatchForACustomBroadcastServer() {
        let active = snapshot(syncHost: "na.zec.rocks", broadcastHost: "mynode.example.com")
        let chosen = LightWalletEndpoint(address: "mynode.example.com", port: 443, secure: true, streamingCallTimeoutInMillis: 0)

        #expect(ServerSetup.shouldWarnBeforeManualSwitch(endpoint: chosen, activeSnapshots: [active]) == true)
    }

    @Test func shouldWarnDoesNotTriggerForTheSanctionedSameServerSnapshot() {
        // sync == broadcast (custom/testnet single-server run) — choosing that SAME server again is
        // the sanctioned mode, not a new link.
        let active = snapshot(syncHost: "testnet.zec.rocks", broadcastHost: "testnet.zec.rocks")
        let chosen = LightWalletEndpoint(address: "testnet.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)

        #expect(ServerSetup.shouldWarnBeforeManualSwitch(endpoint: chosen, activeSnapshots: [active]) == false)
    }

    @Test func shouldWarnDoesNotTriggerWhenNeitherProviderNorHostMatch() {
        let active = snapshot(syncHost: "na.zec.rocks", broadcastHost: "us.zec.stardust.rest")
        let chosen = LightWalletEndpoint(address: "sa.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)

        #expect(ServerSetup.shouldWarnBeforeManualSwitch(endpoint: chosen, activeSnapshots: [active]) == false)
    }

    @Test func shouldWarnDoesNotTriggerWithNoActiveSnapshots() {
        let chosen = LightWalletEndpoint(address: "us.zec.stardust.rest", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
        #expect(ServerSetup.shouldWarnBeforeManualSwitch(endpoint: chosen, activeSnapshots: []) == false)
    }

    // MARK: - MOB-1496 (W4): manual-switch privacy warning — TestStore integration

    @Test func manualSaveOnBroadcastProviderPresentsWarningInsteadOfApplying() async {
        let switchCalls = LockIsolated<Int>(0)
        let active = snapshot(syncHost: "na.zec.rocks", broadcastHost: "us.zec.stardust.rest")

        var initial = ServerSetup.State()
        initial.connectionMode = .manual
        initial.initialConnectionMode = .automatic
        initial.selectedServer = "eu.zec.stardust.rest:443"
        initial.network = .mainnet

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.endpoint = {
                LightWalletEndpoint(address: "na.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
            }
            $0.sdkSynchronizer.switchToEndpoint = { _ in switchCalls.withValue { $0 += 1 } }
            $0.transactionGuard = .testValue
            $0.migrationManager.activeNetworkSnapshots = { [active] }
        }
        store.exhaustivity = .off

        await store.send(.setServerTapped)

        #expect(switchCalls.value == 0, "must not apply until confirmed")
        #expect(store.state.isUpdatingServer == false, "Save/Back must stay enabled while the warning is up")
        #expect(store.state.alert != nil)
        #expect(store.state.pendingManualSwitch?.endpoint.host == "eu.zec.stardust.rest")
        #expect(store.state.pendingManualSwitch?.isCustom == false)
    }

    @Test func manualSwitchPrivacyWarningConfirmedProceedsWithTheNormalApply() async {
        let switched = LockIsolated<LightWalletEndpoint?>(nil)
        var initial = ServerSetup.State()
        initial.pendingManualSwitch = ServerSetup.State.PendingManualSwitch(
            endpoint: LightWalletEndpoint(address: "eu.zec.stardust.rest", port: 443, secure: true, streamingCallTimeoutInMillis: 0),
            isCustom: false
        )
        initial.alert = AlertState.migrationPrivacyWarning()

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.endpoint = {
                LightWalletEndpoint(address: "na.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
            }
            $0.sdkSynchronizer.switchToEndpoint = { switched.setValue($0) }
            $0.userStoredPreferences.setAutomaticServerSelection = { _ in }
            $0.userStoredPreferences.setServer = { _ in }
            $0.transactionGuard = .testValue
        }
        store.exhaustivity = .off

        // MOB-1496 (W4/W7 regression): drive the ACTUAL route TCA uses when "Use it anyway" is
        // tapped. `AlertState<Action>` reuses the parent's own `Action` type, so the button's
        // configured action (`.manualSwitchPrivacyWarningConfirmed`) arrives at the store wrapped
        // as `.alert(.presented(.manualSwitchPrivacyWarningConfirmed))` -- never as the raw
        // top-level action. Sending the raw action directly (as this test used to) false-passes
        // even when a catch-all `case .alert:` swallows every presented payload, because it skips
        // the wrapper entirely.
        await store.send(.alert(.presented(.manualSwitchPrivacyWarningConfirmed)))
        await store.receive(\.manualSwitchPrivacyWarningConfirmed)

        #expect(store.state.alert == nil, "the alert must be cleared once the presented action is routed")
        #expect(store.state.pendingManualSwitch == nil, "the stashed switch must be consumed")
        #expect(store.state.isUpdatingServer == true, "the gated switch must actually start applying")

        await store.receive(\.switchSucceeded)

        #expect(switched.value?.host == "eu.zec.stardust.rest")
        #expect(store.state.alert == nil)
        #expect(store.state.pendingManualSwitch == nil)
        #expect(store.state.isUpdatingServer == false)
    }

    @Test func chooseAnotherDismissesWithoutApplying() async {
        let switchCalls = LockIsolated<Int>(0)
        var initial = ServerSetup.State()
        initial.pendingManualSwitch = ServerSetup.State.PendingManualSwitch(
            endpoint: LightWalletEndpoint(address: "eu.zec.stardust.rest", port: 443, secure: true, streamingCallTimeoutInMillis: 0),
            isCustom: false
        )
        initial.alert = AlertState.migrationPrivacyWarning()

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.sdkSynchronizer.switchToEndpoint = { _ in switchCalls.withValue { $0 += 1 } }
        }

        await store.send(.alert(.dismiss)) {
            $0.alert = nil
            // W4 review Minor (fixed W7): the stashed switch must not linger past the alert it was
            // stashed for.
            $0.pendingManualSwitch = nil
        }

        #expect(switchCalls.value == 0)
    }

    @Test func manualSaveOnTheSanctionedSameServerSnapshotDoesNotWarn() async {
        let switched = LockIsolated<LightWalletEndpoint?>(nil)
        let active = snapshot(syncHost: "na.zec.rocks", broadcastHost: "na.zec.rocks")

        var initial = ServerSetup.State()
        initial.connectionMode = .manual
        initial.initialConnectionMode = .automatic
        initial.selectedServer = "na.zec.rocks:443"
        initial.network = .mainnet

        let store = TestStore(initialState: initial) {
            ServerSetup()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.endpoint = {
                // The CURRENT active endpoint has already drifted from the snapshot's own sync
                // endpoint — the user is manually choosing to go back to it.
                LightWalletEndpoint(address: "eu.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
            }
            $0.sdkSynchronizer.switchToEndpoint = { switched.setValue($0) }
            $0.userStoredPreferences.setAutomaticServerSelection = { _ in }
            $0.userStoredPreferences.setServer = { _ in }
            $0.transactionGuard = .testValue
            $0.migrationManager.activeNetworkSnapshots = { [active] }
        }
        store.exhaustivity = .off

        await store.send(.setServerTapped)
        await store.receive(\.switchSucceeded)

        #expect(switched.value?.host == "na.zec.rocks", "choosing the snapshot's OWN sync server again must not warn")
        #expect(store.state.alert == nil)
    }
}
