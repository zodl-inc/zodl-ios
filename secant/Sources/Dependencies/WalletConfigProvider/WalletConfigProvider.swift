//
//  WalletConfigProvider.swift
//  secant
//
//  Created by Michal Fousek on 23.02.2023.
//

import Foundation

struct WalletConfigProvider {
    private let configSourceProvider: WalletConfigSourceProvider
    private let cache: WalletConfigProviderCache

    init(configSourceProvider: WalletConfigSourceProvider, cache: WalletConfigProviderCache) {
        self.configSourceProvider = configSourceProvider
        self.cache = cache
    }

    func load() async -> WalletConfig {
        let configuration: WalletConfig
        do {
            configuration = try await configSourceProvider.load()
        } catch {
            LoggerProxy.debug("Error when loading feature flags from configuration provider: \(error)")
            if let cachedConfiguration = await cache.load() {
                configuration = cachedConfiguration
            } else {
                configuration = WalletConfig.initial
            }
        }

        let finalConfiguration = merge(configuration: configuration, withDefaultConfiguration: WalletConfig.initial)

        await cache.store(finalConfiguration)

        return finalConfiguration
    }

    // This is used only in debug menu to change configuration for specific flag
    func update(featureFlag: FeatureFlag, isEnabled: Bool) async {
        guard let provider = configSourceProvider as? UserDefaultsWalletConfigStorage else {
            LoggerProxy.debug("This is now only support with UserDefaultsWalletConfigStorage as configurationProvider.")
            return
        }

        await provider.store(featureFlag: featureFlag, isEnabled: isEnabled)
    }

    private func merge(
        configuration: WalletConfig,
        withDefaultConfiguration defaultConfiguration: WalletConfig
    ) -> WalletConfig {
        var rawDefaultFlags = defaultConfiguration.flags
        rawDefaultFlags.merge(configuration.flags, uniquingKeysWith: { $1 })
        return WalletConfig(flags: rawDefaultFlags)
    }
}

protocol WalletConfigSourceProvider: Sendable {
    func load() async throws -> WalletConfig
}

protocol WalletConfigProviderCache: Sendable {
    func load() async -> WalletConfig?
    func store(_ configuration: WalletConfig) async
}
