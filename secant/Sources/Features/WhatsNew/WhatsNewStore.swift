//
//  WhatsNewStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-14-2024
//

import ComposableArchitecture
import Combine
import Foundation

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
        case notifsReportReady(String)
        case onAppear
    }

    static let printNotifsCommand = "print_notifs"

    @Dependency(\.appVersion) var appVersion
    @Dependency(\.date) var date
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.userNotifications) var userNotifications
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
                    guard await localAuthentication.authenticate(for: .settings) else {
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
                // `print_notifs` is a special command, not SQL: it reports the pending
                // Orchard -> Ironwood migration notifications instead of hitting the database.
                let command = state.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if command == Self.printNotifsCommand {
                    return .run { send in
                        let authorization = await userNotifications.authorizationStatus()
                        let pending = await userNotifications.pendingMigrationNotifications()
                        let report = PendingMigrationNotification.debugReport(
                            pending,
                            authorization: authorization,
                            now: date.now()
                        )
                        await send(.notifsReportReady(report))
                    }
                }
                state.output = sdkSynchronizer.debugDatabaseSql(state.query)
                return .none

            case let .notifsReportReady(report):
                state.output = report
                return .none
            }
        }
    }
}
