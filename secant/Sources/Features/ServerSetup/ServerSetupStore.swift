//
//  ServerSetup.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-02-07.
//

import Foundation
import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension LightWalletEndpoint: @retroactive Equatable {
    public static func == (lhs: LightWalletEndpoint, rhs: LightWalletEndpoint) -> Bool {
        lhs.host == rhs.host
        && lhs.port == rhs.port
        && lhs.streamingCallTimeoutInMillis == rhs.streamingCallTimeoutInMillis
        && lhs.singleCallTimeoutInMillis == rhs.singleCallTimeoutInMillis
        && lhs.secure == rhs.secure
    }
}

@Reducer
struct ServerSetup {
    let streamingCallTimeoutInMillis = ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis

    private enum Benchmark {
        // User-visible recommendation pass: can spend longer to rank several servers.
        static let evaluationTimeoutSeconds = 60.0
        static let blocksToDownload: UInt64 = 100
        static let recommendedServerCount = 3
        static let saveCompletionDelay = 1.0
    }

    private enum CancelID {
        case evaluateServers
        case setServer
    }

    @ObservableState
    struct State: Equatable {
        @Presents var alert: AlertState<Action>?
        var connectionMode: UserPreferencesStorage.ConnectionMode
        var customServer: String
        var isEvaluatingServers = false
        var isUpdatingServer = false
        var activeSyncServer: String = ""
        var initialConnectionMode: UserPreferencesStorage.ConnectionMode
        var initialCustomServer: String = ""
        var initialSelectedServer: String?
        var network: NetworkType = .mainnet
        var selectedServer: String?
        var servers: [ZcashSDKEnvironment.Server]
        var topKServers: [ZcashSDKEnvironment.Server]

        var hasChanges: Bool {
            let modeChanged = connectionMode != initialConnectionMode
            let serverChanged = selectedServer != initialSelectedServer
            let customLabel = String(localizable: .serverSetupCustom)
            let customChanged = connectionMode == .manual
                && selectedServer == customLabel
                && customServer != initialCustomServer
            return modeChanged || serverChanged || customChanged
        }

        /// The fastest server from the most recent benchmark (the top of `topKServers`), or nil
        /// before any evaluation has completed.
        var recommendedSyncServer: String? {
            topKServers.first?.value(for: network)
        }

        /// What the Automatic section offers: the benchmarked fastest server once available, else the
        /// current sync server as a placeholder until the first benchmark completes.
        var automaticDisplayServer: String {
            recommendedSyncServer ?? activeSyncServer
        }

        init(
            connectionMode: UserPreferencesStorage.ConnectionMode = .automatic,
            customServer: String = "",
            isEvaluatingServers: Bool = false,
            isUpdatingServer: Bool = false,
            network: NetworkType = .mainnet,
            selectedServer: String? = nil,
            servers: [ZcashSDKEnvironment.Server] = [],
            topKServers: [ZcashSDKEnvironment.Server] = []
        ) {
            self.connectionMode = connectionMode
            self.customServer = customServer
            self.isEvaluatingServers = isEvaluatingServers
            self.isUpdatingServer = isUpdatingServer
            self.initialConnectionMode = connectionMode
            self.network = network
            self.selectedServer = selectedServer
            self.servers = servers
            self.topKServers = topKServers
        }
    }

    enum Action: Equatable, BindableAction {
        case alert(PresentationAction<Action>)
        case binding(BindingAction<State>)
        case connectionModeChanged(UserPreferencesStorage.ConnectionMode)
        case evaluatedServers([LightWalletEndpoint])
        case evaluateServers
        case onAppear
        case onDisappear
        case refreshServersTapped
        case serverSelected(String)
        case setServerTapped
        case switchFailed(ZcashError)
        case switchSucceeded(String)
    }

    init() {}

    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
    @Dependency(\.userStoredPreferences) var userStoredPreferences
    @Dependency(\.transactionGuard) var transactionGuard

    var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .onAppear:
                // Clear transient progress flags so a switch that hung or was cancelled on a previous
                // visit (which leaves isUpdatingServer == true) can't wedge the screen on reopen — both
                // Save and Back are disabled while it is set, and the long-lived serverSetupState is
                // reused by the service-unavailable entry point without resetting to .initial.
                state.isUpdatingServer = false
                state.isEvaluatingServers = false
                state.network = zcashSDKEnvironment.network().networkType
                let syncConfig = zcashSDKEnvironment.serverConfig()
                state.activeSyncServer = syncConfig.serverString()

                if !state.topKServers.isEmpty {
                    let allServers = ZcashSDKEnvironment.servers(for: state.network)
                    state.servers = allServers.filter { !state.topKServers.contains($0) }
                } else {
                    state.servers = ZcashSDKEnvironment.servers(for: state.network)
                }

                // Rehydrate from stored preferences so unsaved selections don't survive navigation.
                let isAutomatic = userStoredPreferences.automaticServerSelection() ?? true
                state.connectionMode = isAutomatic ? .automatic : .manual
                state.customServer = ""
                state.selectedServer = nil
                if state.connectionMode == .manual {
                    if syncConfig.isCustom {
                        state.customServer = syncConfig.serverString()
                        state.selectedServer = String(localizable: .serverSetupCustom)
                    } else {
                        state.selectedServer = syncConfig.serverString()
                    }
                }

                state.initialConnectionMode = state.connectionMode
                state.initialSelectedServer = state.selectedServer
                state.initialCustomServer = state.customServer
                return state.topKServers.isEmpty ? .send(.evaluateServers) : .none

            case .onDisappear:
                // Defense-in-depth: if a Save/evaluate effect is cancelled by an external teardown while
                // the screen is open, neither switchSucceeded/switchFailed nor evaluatedServers fires, so
                // clear the transient progress flags on the way out -- a stuck isUpdatingServer otherwise
                // disables Save/Back. (Back is disabled while updating, so a normal user dismiss already
                // has these false; onAppear also clears them on re-entry.)
                state.isUpdatingServer = false
                state.isEvaluatingServers = false
                return .none

            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .alert:
                return .none

            case .binding:
                return .none

            case .connectionModeChanged(let mode):
                guard !state.isUpdatingServer else { return .none }

                let previousMode = state.connectionMode
                state.connectionMode = mode
                if mode == .automatic {
                    state.selectedServer = state.initialSelectedServer
                    state.customServer = state.initialCustomServer
                    // Benchmark so Automatic can offer the fastest server; reuse a fresh result if one
                    // already exists (mirrors the manual branch's gate).
                    if state.topKServers.isEmpty {
                        return .send(.evaluateServers)
                    }
                } else if mode == .manual {
                    if previousMode != .manual && state.selectedServer == nil {
                        state.selectActiveSyncServerForManualMode()
                    }
                    if state.topKServers.isEmpty {
                        return .send(.evaluateServers)
                    }
                }
                return .none

            case .evaluateServers:
                guard !state.isUpdatingServer else { return .none }

                state.isEvaluatingServers = true
                let network = state.network
                return .run { send in
                    let kBestServers = await sdkSynchronizer.evaluateBestOf(
                        ZcashSDKEnvironment.endpoints(for: network),
                        Benchmark.evaluationTimeoutSeconds,
                        Benchmark.blocksToDownload,
                        Benchmark.recommendedServerCount,
                        network
                    )
                    await send(.evaluatedServers(kBestServers))
                }
                .cancellable(id: CancelID.evaluateServers, cancelInFlight: true)

            case .evaluatedServers(let bestServers):
                state.isEvaluatingServers = false
                state.topKServers = bestServers.map {
                    if ZcashSDKEnvironment.Server.default.value(for: state.network) == $0.server() {
                        ZcashSDKEnvironment.Server.default
                    } else {
                        ZcashSDKEnvironment.Server.hardcoded($0.server())
                    }
                }
                let allServers = ZcashSDKEnvironment.servers(for: state.network)
                state.servers = allServers.filter { !state.topKServers.contains($0) }
                return .none

            case .refreshServersTapped:
                guard !state.isUpdatingServer else { return .none }
                return .send(.evaluateServers)

            case .serverSelected(let serverString):
                guard !state.isUpdatingServer else { return .none }
                state.selectedServer = serverString
                return .none

            case .setServerTapped:
                guard state.hasChanges else { return .none }

                state.isUpdatingServer = true
                let network = state.network
                let timeout = streamingCallTimeoutInMillis

                switch state.connectionMode {
                case .automatic:
                    let cachedRecommendation = state.recommendedSyncServer
                    return .run { send in
                        do {
                            let best: LightWalletEndpoint
                            if let cachedRecommendation,
                               let cached = UserPreferencesStorage.ServerConfig.endpoint(
                                   for: cachedRecommendation,
                                   streamingCallTimeoutInMillis: timeout
                               ) {
                                best = cached
                            } else {
                                let ranked = await sdkSynchronizer.evaluateBestOf(
                                    ZcashSDKEnvironment.endpoints(for: network),
                                    Benchmark.evaluationTimeoutSeconds,
                                    Benchmark.blocksToDownload,
                                    1,
                                    network
                                )
                                best = ranked.first ?? ZcashSDKEnvironment.defaultEndpoint(for: network)
                            }
                            try await applyServerSwitch(best, automatic: true, isCustom: false, send: send)
                        } catch is CancellationError {
                            return
                        } catch {
                            await send(.switchFailed(error.toZcashError()))
                        }
                    }
                    .cancellable(id: CancelID.setServer, cancelInFlight: true)

                case .manual:
                    let serverString = state.selectedServer == String(localizable: .serverSetupCustom)
                        ? state.customServer.trimmingCharacters(in: .whitespaces)
                        : (state.selectedServer ?? "")
                    let isCustom = state.selectedServer == String(localizable: .serverSetupCustom)

                    guard let endpoint = UserPreferencesStorage.ServerConfig.endpoint(
                        for: serverString,
                        streamingCallTimeoutInMillis: timeout
                    ) else {
                        state.isUpdatingServer = false
                        state.alert = AlertState.endpointSwitchFailed(ZcashError.synchronizerServerSwitch)
                        return .none
                    }

                    return .run { send in
                        do {
                            try await applyServerSwitch(endpoint, automatic: false, isCustom: isCustom, send: send)
                        } catch is CancellationError {
                            return
                        } catch {
                            await send(.switchFailed(error.toZcashError()))
                        }
                    }
                    .cancellable(id: CancelID.setServer, cancelInFlight: true)
                }

            case .switchFailed(let error):
                state.isUpdatingServer = false
                state.alert = AlertState.endpointSwitchFailed(error)
                return .none

            case .switchSucceeded(let activeServer):
                state.isUpdatingServer = false
                if state.connectionMode == .automatic {
                    state.selectedServer = nil
                    state.customServer = ""
                }
                state.initialConnectionMode = state.connectionMode
                state.initialSelectedServer = state.selectedServer
                state.initialCustomServer = state.customServer
                state.activeSyncServer = activeServer
                return .none
            }
        }
    }

    /// Switch to `endpoint` (when it differs from the current one), persist the choice, and report
    /// success. Shared by the automatic and manual Save paths: the switch is bounded by a timeout and
    /// serialized against submissions via the transaction guard.
    ///
    /// The preference writes happen inside the guard too — submission endpoints are read at submit
    /// time, so a connection-mode flip that landed mid-submission would change where in-flight
    /// transactions fan out (e.g. a send pinned to a private server fanning out to all public
    /// servers). This matters precisely when the host doesn't change, where no switch would
    /// otherwise serialize the Save.
    private func applyServerSwitch(
        _ endpoint: LightWalletEndpoint,
        automatic: Bool,
        isCustom: Bool,
        send: Send<Action>
    ) async throws {
        let current = zcashSDKEnvironment.endpoint()
        try await transactionGuard.switchWaiting {
            if endpoint.host != current.host || endpoint.port != current.port {
                try await withTimeout(serverSwitchTimeout) {
                    try await sdkSynchronizer.switchToEndpoint(endpoint)
                }
            }

            userStoredPreferences.setAutomaticServerSelection(automatic)
            try userStoredPreferences.setServer(endpoint.serverConfig(isCustom: isCustom))

            // [#1755] v0.7 P1b: keep the slipstream engine's probe grid in lockstep with the
            // just-persisted connection mode — Automatic arms the per-pass health probe +
            // wire failover over all known servers; Manual revokes it (empty list = the
            // selected server is used exclusively). Applies from the next sync pass.
            await sdkSynchronizer.setAlternateEndpoints(
                automatic
                    ? ZcashSDKEnvironment.endpoints(for: zcashSDKEnvironment.network().networkType)
                    : []
            )
        }

        try await mainQueue.sleep(for: .seconds(Benchmark.saveCompletionDelay))
        await send(.switchSucceeded(endpoint.server()))
    }
}

private extension ServerSetup.State {
    /// When switching to Manual, preselect the currently-active sync server.
    mutating func selectActiveSyncServerForManualMode() {
        guard let endpoint = UserPreferencesStorage.ServerConfig.endpoint(
            for: activeSyncServer,
            streamingCallTimeoutInMillis: ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis
        ) else {
            selectedServer = nil
            customServer = ""
            return
        }

        let endpointString = endpoint.server()
        let isKnown = ZcashSDKEnvironment.servers(for: network).contains { server in
            server.value(for: network) == endpointString
        }
        if isKnown {
            selectedServer = endpointString
            customServer = ""
        } else {
            selectedServer = String(localizable: .serverSetupCustom)
            customServer = endpointString
        }
    }
}

// MARK: Alerts

extension AlertState where Action == ServerSetup.Action {
    static func endpointSwitchFailed(_ error: ZcashError) -> AlertState {
        AlertState {
            TextState(String(localizable: .serverSetupAlertFailedTitle))
        } actions: {
            ButtonState(action: .alert(.dismiss)) {
                TextState(String(localizable: .generalOk))
            }
        } message: {
            TextState(String(localizable: .serverSetupAlertFailedMessage(error.detailedMessage)))
        }
    }
}

extension ServerSetup.State {
    static let initial = ServerSetup.State()
}
