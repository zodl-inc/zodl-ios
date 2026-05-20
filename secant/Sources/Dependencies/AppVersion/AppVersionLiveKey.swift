//
//  AppVersionLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.11.2022.
//

import Foundation
import ComposableArchitecture

extension AppVersionClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            appVersion: { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" },
            appBuild: { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
        )
    }
}
