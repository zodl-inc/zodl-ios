//
//  AppVersionInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.11.2022.
//

import ComposableArchitecture

extension DependencyValues {
    var appVersion: AppVersionClient {
        get { self[AppVersionClient.self] }
        set { self[AppVersionClient.self] = newValue }
    }
}

@DependencyClient
struct AppVersionClient {
    var appVersion: @Sendable () -> String = { "" }
    var appBuild: @Sendable () -> String = { "" }
}
