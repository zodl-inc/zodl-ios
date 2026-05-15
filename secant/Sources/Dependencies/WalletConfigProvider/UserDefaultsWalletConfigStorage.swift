//
//  UserDefaultsWalletConfigStorage.swift
//  secant
//
//  Created by Michal Fousek on 23.02.2023.
//

import Foundation

typealias UserDefaultsWalletConfigProvider = UserDefaultsWalletConfigStorage
typealias UserDefaultsWalletConfigProviderCache = UserDefaultsWalletConfigStorage

struct UserDefaultsWalletConfigStorage {
    private let userDefaults = UserDefaults.standard

    enum InternalError: Error {
        case noValueStored
        case unableToDeserializeData
    }

    enum Constants {
        static let providerKey = "feature_flags_ud_config_provider"
        static let cacheKey = "feature_flags_ud_config_cache"
    }

    init() {}
    
    private func load(key: String) async throws -> WalletConfig {
        guard let data = userDefaults.data(forKey: key) else { throw InternalError.noValueStored }
        do {
            let rawFlags = try PropertyListDecoder().decode(WalletConfig.RawFlags.self, from: data)
            return WalletConfig(flags: rawFlags)
        } catch {
            LoggerProxy.debug("Error when decoding feature flags from user defaults: \(error)")
            throw InternalError.unableToDeserializeData
        }
    }

    private func store(flags: WalletConfig.RawFlags, key: String) async {
        do {
            let data = try PropertyListEncoder().encode(flags)
            userDefaults.set(data, forKey: key)
        } catch {
            LoggerProxy.debug("Can't store/encode feature flags when updating user defaults: \(error)")
        }
    }

    // This is used only in debug menu to change configuration for specific flag
    func store(featureFlag: FeatureFlag, isEnabled: Bool) async {
        let currentConfig = (try? await load(key: Constants.providerKey)) ?? WalletConfig.initial
        var rawFlags = currentConfig.flags
        rawFlags[featureFlag] = isEnabled

        await store(flags: rawFlags, key: Constants.providerKey)
    }
}

extension UserDefaultsWalletConfigStorage: WalletConfigSourceProvider {
    func load() async throws -> WalletConfig {
        return try await load(key: Constants.providerKey)
    }
}

extension UserDefaultsWalletConfigStorage: WalletConfigProviderCache {
    func load() async -> WalletConfig? {
        do {
            return try await load(key: Constants.cacheKey)
        } catch {
            LoggerProxy.debug("Can't load feature flags from cache: \(error)")
            return nil
        }
    }

    func store(_ configuration: WalletConfig) async {
        await store(flags: configuration.flags, key: Constants.cacheKey)
    }
}
