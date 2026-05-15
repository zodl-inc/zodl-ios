//
//  WalletConfigProviderLiveKey.swift
//  secant
//
//  Created by Michal Fousek on 23.02.2023.
//

import ComposableArchitecture
import Foundation

extension WalletConfigProviderClient: DependencyKey {
    static let liveValue = WalletConfigProviderClient.live()

    static var defaultWalletConfigProvider: WalletConfigProvider {
        WalletConfigProvider(
            configSourceProvider: UserDefaultsWalletConfigProvider(),
            cache: UserDefaultsWalletConfigProviderCache()
        )
    }

    static func live(walletConfigProvider: WalletConfigProvider = WalletConfigProviderClient.defaultWalletConfigProvider) -> Self {
        Self(
            load: { await walletConfigProvider.load() },
            update: { flag, isEnabled in
                await walletConfigProvider.update(featureFlag: flag, isEnabled: isEnabled)
            }
        )
    }
}
