//
//  AppVersionMocks.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.11.2022.
//

extension AppVersionClient {
    static let mock = Self(
        appVersion: { "0.0.1" },
        appBuild: { "31" }
    )
}
