//
//  WalletConfigProviderInterface.swift
//  secant
//
//  Created by Michal Fousek on 23.02.2023.
//

import ComposableArchitecture
import Foundation

extension DependencyValues {
    var walletConfigProvider: WalletConfigProviderClient {
        get { self[WalletConfigProviderClient.self] }
        set { self[WalletConfigProviderClient.self] = newValue }
    }
}

@DependencyClient
struct WalletConfigProviderClient {
    var load: @Sendable () async -> WalletConfig = { WalletConfig.initial }
    var update: @Sendable (FeatureFlag, Bool) async -> Void
}
