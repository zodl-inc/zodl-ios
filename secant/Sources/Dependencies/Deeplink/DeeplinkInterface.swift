//
//  DeeplinkInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 11.11.2022.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var deeplink: DeeplinkClient {
        get { self[DeeplinkClient.self] }
        set { self[DeeplinkClient.self] = newValue }
    }
}

@DependencyClient
struct DeeplinkClient {
    var resolveDeeplinkURL: @Sendable (URL, NetworkType, DerivationToolClient) throws -> Deeplink.Destination
}
