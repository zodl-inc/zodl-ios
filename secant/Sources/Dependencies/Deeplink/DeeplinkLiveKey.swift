//
//  DeeplinkLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 11.11.2022.
//

import ComposableArchitecture

extension DeeplinkClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            resolveDeeplinkURL: { try Deeplink.resolveDeeplinkURL($0, networkType: $1, isValidZcashAddress: $2.isZcashAddress) }
        )
    }
}
