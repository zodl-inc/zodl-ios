//
//  WhatsNewStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-14-2024
//

import ComposableArchitecture
import WhatsNewProvider
import AppVersion
import SDKSynchronizer
import LocalAuthenticationHandler

@Reducer
public struct WhatsNew {
    @ObservableState
    public struct State: Equatable {
        public var appVersion = ""
        public var appBuild = ""
        public var isInDebugMode = false
        public var latest: WhatNewRelease
        public var releases: WhatNewReleases
        
        // debug mode
        public var query = ""
        public var output = ""

        public init(
            latest: WhatNewRelease = .zero,
            releases: WhatNewReleases = .zero
        ) {
            self.latest = latest
            self.releases = releases
        }
    }
    
    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<WhatsNew.State>)
        case enableDebugMode
        case executeQuery
        case executeQueryRequested
        case exitDebug
        case onAppear
    }
    
    @Dependency(\.appVersion) var appVersion
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.whatsNewProvider) var whatsNewProvider
    
    public init() { }
    
    public var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.appVersion = appVersion.appVersion()
                state.appBuild = appVersion.appBuild()
                state.latest = whatsNewProvider.latest()
                state.releases = whatsNewProvider.all()
                return .none
                
            case .binding:
                return .none
                
            case .executeQueryRequested:
                guard !state.query.isEmpty else {
                    state.output = "Fill in some query to execute"
                    return .none
                }
                return .run { send in
                    guard await localAuthentication.authenticate() else {
                        return
                    }
                    
                    await send(.executeQuery)
                }

            case .enableDebugMode:
                state.isInDebugMode = true
                return .none

            case .exitDebug:
                state.isInDebugMode = false
                return .none

            case .executeQuery:
                state.output = sdkSynchronizer.debugDatabaseSql(state.query)
                return .none
            }
        }
    }
}
