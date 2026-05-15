//
//  ZcashSDKEnvironmentLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 13.11.2022.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension ZcashSDKEnvironment: DependencyKey {

    static let liveValue: ZcashSDKEnvironment = Self.live(network: TargetConstants.zcashNetwork)

    static func live(network: ZcashNetwork) -> Self {
        Self(
            latestCheckpoint: BlockHeight.ofLatestCheckpoint(network: network),
            endpoint: {
                ZcashSDKEnvironment.serverConfig(
                    for: network.networkType
                ).endpoint(streamingCallTimeoutInMillis: ZcashSDKConstants.streamingCallTimeoutInMillis)
            },
            exchangeRateIPRateLimit: 120,
            exchangeRateStaleLimit: 15 * 60,
            memoCharLimit: MemoBytes.capacity,
            mnemonicWordsMaxCount: ZcashSDKConstants.mnemonicWordsMaxCount,
            network: network,
            requiredTransactionConfirmations: ZcashSDKConstants.requiredTransactionConfirmations,
            sdkVersion: "0.18.1-beta",
            serverConfig: { ZcashSDKEnvironment.serverConfig(for: network.networkType) },
            servers: ZcashSDKEnvironment.servers(for: network.networkType),
            shieldingThreshold: Zatoshi(100_000),
            tokenName: network.networkType == .testnet ? "TAZ" : "ZEC"
        )
    }
}

extension ZcashSDKEnvironment {
    static func serverConfig(for network: NetworkType) -> UserPreferencesStorage.ServerConfig {
        migrateVersion1IfNeeded()
        
        guard let serverConfig = storedServerConfig() else {
            return defaultEndpoint(for: network).serverConfig()
        }
        
        // Migrate lwdX.zcash-infra.com servers to custom
        if serverConfig.host.hasSuffix(".zcash-infra.com") {
            return UserPreferencesStorage.ServerConfig(host: serverConfig.host, port: serverConfig.port, isCustom: true)
        }
        
        return serverConfig
    }
    
    static func migrateVersion1IfNeeded() {
        @Dependency(\.userStoredPreferences) var userStoredPreferences
        @Dependency(\.userDefaults) var userDefaults

        let streamingCallTimeoutInMillis = ZcashSDKConstants.streamingCallTimeoutInMillis
        let udServerKey = "zashi_udServerKey"
        let udCustomServerKey = "zashi_udCustomServerKey"

        // only if there's no ServerConfig stored
        guard userStoredPreferences.server() == nil else {
            userDefaults.remove(udServerKey)
            userDefaults.remove(udCustomServerKey)
            return
        }
        
        // get server key
        guard let storedKey = userDefaults.objectForKey(udServerKey) as? String else {
            userDefaults.remove(udServerKey)
            userDefaults.remove(udCustomServerKey)
            return
        }
        
        // ensure custom server is preserved
        if storedKey == "custom" {
            if let customValue = userDefaults.objectForKey(udCustomServerKey) as? String {
                if let serverConfig = UserPreferencesStorage.ServerConfig.endpoint(
                    for: customValue,
                    streamingCallTimeoutInMillis: streamingCallTimeoutInMillis)?.serverConfig(
                        isCustom: true
                    ) 
                {
                    try? userStoredPreferences.setServer(serverConfig)
                }
            }
        } else if storedKey == "mainnet" {
            let serverConfig = UserPreferencesStorage.ServerConfig(host: "mainnet.lightwalletd.com", port: 9067, isCustom: true)
            try? userStoredPreferences.setServer(serverConfig)
        } else {
            // some of the lwd servers
            let serverConfig = UserPreferencesStorage.ServerConfig(host: "\(storedKey.dropLast(2)).lightwalletd.com", port: 443, isCustom: true)
            try? userStoredPreferences.setServer(serverConfig)
        }
    }
    
    static func storedServerConfig() -> UserPreferencesStorage.ServerConfig? {
        @Dependency(\.userStoredPreferences) var userStoredPreferences
        return userStoredPreferences.server()
    }
}
