//
//  ServerSetup.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-02-07.
//

import Foundation
import ComposableArchitecture
import ZcashLightClientKit

import Generated
import SDKSynchronizer
import UserPreferencesStorage
import ZcashSDKEnvironment

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
public struct ServerSetup {
    let streamingCallTimeoutInMillis = ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis

    @ObservableState
    public struct State: Equatable {
        var activeServer: String
        @Presents var alert: AlertState<Action>?
        var customServer: String
        var isEvaluatingServers = false
        var isUpdatingServer = false
        var initialServer: String
        var network: NetworkType = .mainnet
        var selectedServer: String?
        var servers: [ZcashSDKEnvironment.Server]
        var topKServers: [ZcashSDKEnvironment.Server]
        
        public init(
            activeServer: String = "",
            customServer: String = "",
            isEvaluatingServers: Bool = false,
            isUpdatingServer: Bool = false,
            initialServer: String = "",
            network: NetworkType = .mainnet,
            selectedServer: String? = nil,
            servers: [ZcashSDKEnvironment.Server] = [],
            topKServers: [ZcashSDKEnvironment.Server] = []
        ) {
            self.activeServer = activeServer
            self.customServer = customServer
            self.isUpdatingServer = isUpdatingServer
            self.initialServer = initialServer
            self.network = network
            self.selectedServer = selectedServer
            self.servers = servers
            self.topKServers = topKServers
        }
    }
    
    public enum Action: Equatable, BindableAction {
        case alert(PresentationAction<Action>)
        case binding(BindingAction<State>)
        case evaluatedServers([LightWalletEndpoint])
        case evaluateServers
        case onAppear
        case onDisappear
        case refreshServersTapped
        case setServerTapped
        case someServerTapped(ZcashSDKEnvironment.Server)
        case switchFailed(ZcashError)
        case switchSucceeded
    }
    
    public init() {}
    
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
    @Dependency(\.userStoredPreferences) var userStoredPreferences

    public var body: some ReducerOf<Self> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.network = zcashSDKEnvironment.network.networkType
                
                if !state.topKServers.isEmpty {
                    let allServers = ZcashSDKEnvironment.servers(for: state.network)
                    state.servers = allServers.filter {
                        !state.topKServers.contains($0)
                    }
                } else {
                    state.servers = ZcashSDKEnvironment.servers(for: state.network)
                }

                let serverConfig = zcashSDKEnvironment.serverConfig()
                
                if serverConfig.isCustom {
                    state.initialServer = L10n.ServerSetup.custom
                    state.customServer = serverConfig.serverString()
                } else {
                    state.initialServer = serverConfig.serverString()
                }
                
                state.activeServer = state.initialServer
                return state.topKServers.isEmpty ? .send(.evaluateServers) : .none

            case .onDisappear:
                // __LD2 TESTing
                print("__LD ServerSetup.onDisappear")
                state.selectedServer = nil
                return .none

            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .alert:
                return .none

            case .binding:
                return .none
            
            case .evaluateServers:
                state.isEvaluatingServers = true
                return .run { send in
                    let kBestServers = await sdkSynchronizer.evaluateBestOf(
                        ZcashSDKEnvironment.endpoints(),
                        300.0,
                        60.0,
                        100,
                        3,
                        .mainnet
                    )
                    
                    await send(.evaluatedServers(kBestServers))
                }
                
            case .evaluatedServers(let bestServers):
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
                return .none
                
            case .refreshServersTapped:
                return .send(.evaluateServers)

            case .setServerTapped:
                guard state.initialServer != state.selectedServer || state.selectedServer == L10n.ServerSetup.custom else {
                    return .none
                }
                
                state.isUpdatingServer = true
                
                // custom server needs to be stored first
                var input = state.selectedServer ?? state.activeServer
                if input == L10n.ServerSetup.custom {
                    input = state.customServer
                }
                
                return .run { [input] send in
                    do {
                        let endpoint = UserPreferencesStorage.ServerConfig.endpoint(
                            for: input,
                            streamingCallTimeoutInMillis: streamingCallTimeoutInMillis
                        )
                        guard let endpoint else {
                            throw ZcashError.synchronizerServerSwitch
                        }
                        try await sdkSynchronizer.switchToEndpoint(endpoint)
                        try await mainQueue.sleep(for: .seconds(1))
                        await send(.switchSucceeded)
                    } catch {
                        await send(.switchFailed(error.toZcashError()))
                    }
                }
                
            case .someServerTapped(let newChange):
                state.selectedServer = newChange.value(for: state.network)
                return .none

            case .switchFailed(let error):
                state.isUpdatingServer = false
                state.alert = AlertState.endpoindSwitchFailed(error)
                return .none
                
            case .switchSucceeded:
                state.isUpdatingServer = false
                state.initialServer = state.selectedServer ?? state.activeServer
                state.activeServer = state.initialServer
                var input = state.selectedServer ?? state.activeServer
                var isCustom = false
                state.selectedServer = nil

                if input == L10n.ServerSetup.custom {
                    input = state.customServer
                    isCustom = true
                }

                if let serverConfig = UserPreferencesStorage.ServerConfig.config(
                    for: input,
                    isCustom: isCustom,
                    streamingCallTimeoutInMillis: streamingCallTimeoutInMillis
                ) {
                    do {
                        try userStoredPreferences.setServer(serverConfig)
                    } catch UserPreferencesStorage.UserPreferencesStorageError.serverConfig {
                        return .send(.switchFailed(ZcashError.unknown(UserPreferencesStorage.UserPreferencesStorageError.serverConfig)))
                    } catch {
                        return .send(.switchFailed(ZcashError.unknown(error)))
                    }
                }
                return .none
            }
        }
    }
}

// MARK: Alerts

extension AlertState where Action == ServerSetup.Action {
    public static func endpoindSwitchFailed(_ error: ZcashError) -> AlertState {
        AlertState {
            TextState(L10n.ServerSetup.Alert.Failed.title)
        } actions: {
            ButtonState(action: .alert(.dismiss)) {
                TextState(L10n.General.ok)
            }
        } message: {
            TextState(L10n.ServerSetup.Alert.Failed.message(error.detailedMessage))
        }
    }
}
