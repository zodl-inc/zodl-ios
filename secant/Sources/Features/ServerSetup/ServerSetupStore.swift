//
//  ServerSetup.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-02-07.
//

import Foundation
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

    private enum ServerSetupRecommendationDefaults {
        // User-visible recommendation pass. This can spend longer to rank several servers.
        static let connectionTimeoutMilliseconds = 300.0
        static let evaluationTimeoutSeconds = 60.0
        static let blocksToDownload: UInt64 = 100
        static let recommendedServerCount = 3
        static let fallbackServerCount = 1
        static let saveCompletionDelay: DispatchQueue.SchedulerTimeType.Stride = .seconds(1)
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
        var recommendedSyncServer: String?
        var initialConnectionMode: UserPreferencesStorage.ConnectionMode
        var initialCustomServer: String = ""
        var initialSelectedServer: String?
        var network: NetworkType = .mainnet
        var serverEvaluationRequestID = 0
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

        init(
            connectionMode: UserPreferencesStorage.ConnectionMode = .automatic,
            customServer: String = "",
            isEvaluatingServers: Bool = false,
            isUpdatingServer: Bool = false,
            recommendedSyncServer: String? = nil,
            network: NetworkType = .mainnet,
            serverEvaluationRequestID: Int = 0,
            selectedServer: String? = nil,
            servers: [ZcashSDKEnvironment.Server] = [],
            topKServers: [ZcashSDKEnvironment.Server] = []
        ) {
            self.connectionMode = connectionMode
            self.customServer = customServer
            self.isEvaluatingServers = isEvaluatingServers
            self.isUpdatingServer = isUpdatingServer
            self.recommendedSyncServer = recommendedSyncServer
            self.initialConnectionMode = connectionMode
            self.network = network
            self.serverEvaluationRequestID = serverEvaluationRequestID
            self.selectedServer = selectedServer
            self.servers = servers
            self.topKServers = topKServers
        }
    }

    enum Action: Equatable, BindableAction {
        case alert(PresentationAction<Action>)
        case automaticEndpointUpdated(String)
        case binding(BindingAction<State>)
        case connectionModeChanged(UserPreferencesStorage.ConnectionMode)
        case evaluatedServers(Int, [LightWalletEndpoint])
        case evaluateServers
        case onAppear
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

    var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.network = zcashSDKEnvironment.network().networkType
                let syncConfig = zcashSDKEnvironment.serverConfig()
                state.activeSyncServer = syncConfig.serverString()
                state.recommendedSyncServer = nil

                if !state.topKServers.isEmpty {
                    let allServers = ZcashSDKEnvironment.servers(for: state.network)
                    state.servers = allServers.filter {
                        !state.topKServers.contains($0)
                    }
                } else {
                    state.servers = ZcashSDKEnvironment.servers(for: state.network)
                }

                // Rehydrate from stored preferences so unsaved selections do not survive navigation.
                let config = userStoredPreferences.selectedServers()
                state.connectionMode = config?.mode ?? .automatic
                state.customServer = ""
                state.selectedServer = nil
                if config?.mode == .manual, let server = config?.servers.first {
                    if server.isCustom {
                        state.customServer = server.serverString()
                        state.selectedServer = String(localizable: .serverSetupCustom)
                    } else {
                        state.selectedServer = server.serverString()
                    }
                }

                state.initialConnectionMode = state.connectionMode
                state.initialSelectedServer = state.selectedServer
                state.initialCustomServer = state.customServer
                return state.topKServers.isEmpty ? .send(.evaluateServers) : .none

            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .alert:
                return .none

            case .automaticEndpointUpdated(let server):
                if state.connectionMode == .automatic {
                    state.activeSyncServer = server
                }
                return .none

            case .binding:
                return .none

            case .connectionModeChanged(let mode):
                guard !state.isUpdatingServer else {
                    return .none
                }

                let previousMode = state.connectionMode
                state.connectionMode = mode
                if mode == .automatic {
                    state.selectedServer = state.initialSelectedServer
                    state.customServer = state.initialCustomServer
                } else if mode == .manual {
                    if previousMode != .manual && state.selectedServer == nil {
                        if !state.activeSyncServer.isEmpty {
                            let syncConfig = zcashSDKEnvironment.serverConfig()
                            state.activeSyncServer = syncConfig.serverString()
                        }
                        state.selectActiveSyncServerForManualMode()
                    }
                    if state.topKServers.isEmpty {
                        return .send(.evaluateServers)
                    }
                }
                return .none

            case .evaluateServers:
                guard !state.isUpdatingServer else {
                    return .none
                }

                state.isEvaluatingServers = true
                state.serverEvaluationRequestID += 1
                let requestID = state.serverEvaluationRequestID
                let network = state.network
                return .run { send in
                    let kBestServers = await sdkSynchronizer.evaluateBestOf(
                        ZcashSDKEnvironment.endpoints(for: network),
                        ServerSetupRecommendationDefaults.connectionTimeoutMilliseconds,
                        ServerSetupRecommendationDefaults.evaluationTimeoutSeconds,
                        ServerSetupRecommendationDefaults.blocksToDownload,
                        ServerSetupRecommendationDefaults.recommendedServerCount,
                        network
                    )

                    await send(.evaluatedServers(requestID, kBestServers))
                }
                .cancellable(id: CancelID.evaluateServers, cancelInFlight: true)

            case .evaluatedServers(let requestID, let bestServers):
                guard requestID == state.serverEvaluationRequestID else {
                    return .none
                }

                state.isEvaluatingServers = false
                state.topKServers = bestServers.map {
                    if ZcashSDKEnvironment.Server.default.value(for: state.network) == $0.server() {
                        ZcashSDKEnvironment.Server.default
                    } else {
                        ZcashSDKEnvironment.Server.hardcoded("\($0.host):\($0.port)")
                    }
                }
                let allServers = ZcashSDKEnvironment.servers(for: state.network)
                state.servers = allServers.filter {
                    !state.topKServers.contains($0)
                }
                state.recommendedSyncServer = bestServers.first?.server()

                return .none

            case .refreshServersTapped:
                guard !state.isUpdatingServer else {
                    return .none
                }

                return .send(.evaluateServers)

            case .serverSelected(let serverString):
                guard !state.isUpdatingServer else {
                    return .none
                }

                state.selectedServer = serverString
                return .none

            case .setServerTapped:
                guard state.hasChanges else {
                    return .none
                }

                state.isUpdatingServer = true
                let network = state.network

                switch state.connectionMode {
                case .automatic:
                    // Use already-evaluated best server when available to avoid a redundant benchmark
                    let cachedRecommendation = state.recommendedSyncServer
                    let timeout = streamingCallTimeoutInMillis
                    let previousConfig = userStoredPreferences.selectedServers()

                    return .run { send in
                        var endpointBeforeSwitch: LightWalletEndpoint?
                        var attemptedEndpointSwitch = false

                        do {
                            let best: LightWalletEndpoint

                            if let cachedRecommendation,
                               let cached = UserPreferencesStorage.ServerConfig.endpoint(
                                   for: cachedRecommendation,
                                   streamingCallTimeoutInMillis: timeout
                               ) {
                                best = cached
                            } else {
                                let bestServers = await sdkSynchronizer.evaluateBestOf(
                                    ZcashSDKEnvironment.endpoints(for: network),
                                    ServerSetupRecommendationDefaults.connectionTimeoutMilliseconds,
                                    ServerSetupRecommendationDefaults.evaluationTimeoutSeconds,
                                    ServerSetupRecommendationDefaults.blocksToDownload,
                                    ServerSetupRecommendationDefaults.fallbackServerCount,
                                    network
                                )
                                best = bestServers.first ?? ZcashSDKEnvironment.defaultEndpoint(for: network)
                            }

                            let currentEndpoint = zcashSDKEnvironment.endpoint()
                            endpointBeforeSwitch = currentEndpoint
                            let serverConfig = UserPreferencesStorage.ServerConfig(
                                host: best.host, port: best.port, isCustom: false
                            )
                            // In automatic mode, selectedServers stores only the mode while the
                            // legacy server key caches the active benchmarked endpoint.
                            try userStoredPreferences.setSelectedServers(
                                UserPreferencesStorage.SelectedServersConfig(mode: .automatic, servers: [])
                            )

                            if best.host != currentEndpoint.host || best.port != currentEndpoint.port {
                                attemptedEndpointSwitch = true
                                try await EndpointSwitching.coordinator.switchToEndpoint(
                                    best,
                                    performSwitch: sdkSynchronizer.switchToEndpoint
                                )
                            }

                            try userStoredPreferences.setServer(serverConfig)

                            let bestServerString = "\(best.host):\(best.port)"
                            try await mainQueue.sleep(for: ServerSetupRecommendationDefaults.saveCompletionDelay)
                            await send(.switchSucceeded(bestServerString))
                        } catch is CancellationError {
                            return
                        } catch {
                            if let previousConfig {
                                try? userStoredPreferences.setSelectedServers(previousConfig)
                            }
                            if attemptedEndpointSwitch, let endpointBeforeSwitch {
                                try? await EndpointSwitching.coordinator.switchToEndpoint(
                                    endpointBeforeSwitch,
                                    performSwitch: sdkSynchronizer.switchToEndpoint
                                )
                            }
                            await send(.switchFailed(error.toZcashError()))
                        }
                    }
                    .cancellable(id: CancelID.setServer, cancelInFlight: true)

                case .manual:
                    // Switch to the user's selected server
                    let serverString = state.selectedServer == String(localizable: .serverSetupCustom)
                        ? state.customServer
                        : (state.selectedServer ?? "")

                    guard let endpoint = UserPreferencesStorage.ServerConfig.endpoint(
                        for: serverString,
                        streamingCallTimeoutInMillis: streamingCallTimeoutInMillis
                    ) else {
                        return .send(.switchFailed(ZcashError.synchronizerServerSwitch))
                    }

                    // Manual mode is driven by selectedServers, so persist the intent before
                    // the async switch. This lets the Root benchmark observe manual mode
                    // immediately and keeps restart behavior aligned with the user's choice.
                    let isCustom = !ZcashSDKEnvironment.isKnownEndpoint(
                        host: endpoint.host, port: endpoint.port, network: network
                    )
                    let serverConfig = UserPreferencesStorage.ServerConfig(
                        host: endpoint.host, port: endpoint.port, isCustom: isCustom
                    )
                    let currentEndpoint = zcashSDKEnvironment.endpoint()
                    let previousConfig = userStoredPreferences.selectedServers()
                    do {
                        try userStoredPreferences.setSelectedServers(
                            UserPreferencesStorage.SelectedServersConfig(mode: .manual, servers: [serverConfig])
                        )
                    } catch {
                        return .send(.switchFailed(error.toZcashError()))
                    }

                    return .run { send in
                        let shouldSwitchEndpoint = endpoint.host != currentEndpoint.host
                            || endpoint.port != currentEndpoint.port
                        do {
                            if shouldSwitchEndpoint {
                                try await EndpointSwitching.coordinator.switchToEndpoint(
                                    endpoint,
                                    performSwitch: sdkSynchronizer.switchToEndpoint
                                )
                            }

                            // Cache the active endpoint for automatic mode and legacy callers.
                            try userStoredPreferences.setServer(serverConfig)

                            let serverStr = "\(endpoint.host):\(endpoint.port)"
                            try await mainQueue.sleep(for: ServerSetupRecommendationDefaults.saveCompletionDelay)
                            await send(.switchSucceeded(serverStr))
                        } catch is CancellationError {
                            return
                        } catch {
                            // Revert the intent flag on failure
                            if let previousConfig {
                                try? userStoredPreferences.setSelectedServers(previousConfig)
                            }
                            if shouldSwitchEndpoint {
                                try? await EndpointSwitching.coordinator.switchToEndpoint(
                                    currentEndpoint,
                                    performSwitch: sdkSynchronizer.switchToEndpoint
                                )
                            }
                            await send(.switchFailed(error.toZcashError()))
                        }
                    }
                    .cancellable(id: CancelID.setServer, cancelInFlight: true)
                }

            case .switchFailed(let error):
                state.isUpdatingServer = false
                state.alert = AlertState.endpointSwitchFailed(error)
                return .none

            case .switchSucceeded(let bestServer):
                state.isUpdatingServer = false
                if state.connectionMode == .automatic {
                    state.selectedServer = nil
                    state.customServer = ""
                }
                state.initialConnectionMode = state.connectionMode
                state.initialSelectedServer = state.selectedServer
                state.initialCustomServer = state.customServer
                state.activeSyncServer = bestServer
                return .none
            }
        }
    }
}

private extension ServerSetup.State {
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
        if ZcashSDKEnvironment.isKnownEndpoint(host: endpoint.host, port: endpoint.port, network: network) {
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
