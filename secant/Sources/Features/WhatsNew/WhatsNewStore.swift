//
//  WhatsNewStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-14-2024
//

import ComposableArchitecture

@Reducer
struct WhatsNew {
    @ObservableState
    struct State: Equatable {
        var appVersion = ""
        var appBuild = ""
        var isInDebugMode = false
        var latest: WhatNewRelease
        var releases: WhatNewReleases
        
        // debug mode
        var query = ""
        var output = ""

        init(
            latest: WhatNewRelease = .zero,
            releases: WhatNewReleases = .zero
        ) {
            self.latest = latest
            self.releases = releases
        }
    }
    
    enum Action: BindableAction, Equatable {
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
    
    init() { }
    
    var body: some Reducer<State, Action> {
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
