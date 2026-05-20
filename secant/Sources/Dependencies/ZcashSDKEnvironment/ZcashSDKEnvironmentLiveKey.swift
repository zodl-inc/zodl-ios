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
            latestCheckpoint: { BlockHeight.ofLatestCheckpoint(network: network) },
            endpoint: {
                ZcashSDKEnvironment.serverConfig(
                    for: network.networkType
                ).endpoint(streamingCallTimeoutInMillis: ZcashSDKConstants.streamingCallTimeoutInMillis)
            },
            exchangeRateIPRateLimit: { 120 },
            exchangeRateStaleLimit: { 15 * 60 },
            memoCharLimit: { MemoBytes.capacity },
            mnemonicWordsMaxCount: { ZcashSDKConstants.mnemonicWordsMaxCount },
            network: { network },
            requiredTransactionConfirmations: { ZcashSDKConstants.requiredTransactionConfirmations },
            sdkVersion: { "0.18.1-beta" },
            serverConfig: { ZcashSDKEnvironment.serverConfig(for: network.networkType) },
            servers: { ZcashSDKEnvironment.servers(for: network.networkType) },
            shieldingThreshold: { Zatoshi(100_000) },
            tokenName: { network.networkType == .testnet ? "TAZ" : "ZEC" }
        )
    }
}

extension ZcashSDKEnvironment {
    static func serverConfig(for network: NetworkType) -> UserPreferencesStorage.ServerConfig {
        migrateVersion1IfNeeded()
        initializeSelectedServersIfNeeded(for: network)

        @Dependency(\.userStoredPreferences) var userStoredPreferences
        if let selected = userStoredPreferences.selectedServers(),
           selected.mode == .manual,
           let first = selected.servers.first {
            return normalizedStoredServerConfig(first)
        }

        guard let serverConfig = storedServerConfig() else {
            return defaultEndpoint(for: network).serverConfig()
        }

        return normalizedStoredServerConfig(serverConfig)
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
    
    /// On first launch (no selected servers config), initialize based on existing server preference:
    /// - Custom server users: manual mode with their custom server (privacy)
    /// - Non-default known server users: manual mode with their selected server
    /// - Unknown non-default server users: manual mode, normalized as custom
    /// - Default known server users / new users: automatic mode (sends to all servers)
    static func initializeSelectedServersIfNeeded(for network: NetworkType) {
        @Dependency(\.userStoredPreferences) var userStoredPreferences

        guard userStoredPreferences.selectedServers() == nil else { return }

        if let existing = userStoredPreferences.server() {
            let normalizedServer = migrationServerConfig(existing, network: network)

            if shouldPreserveAsManualSelection(normalizedServer, network: network) {
                do {
                    try userStoredPreferences.setSelectedServers(.init(mode: .manual, servers: [normalizedServer]))
                } catch {
                    LoggerProxy.error("[Migration] Failed to persist manual server selection: \(error)")
                }
                return
            }
        }

        do {
            try userStoredPreferences.setSelectedServers(.init(mode: .automatic, servers: []))
        } catch {
            LoggerProxy.error("[Migration] Failed to persist default server selection: \(error)")
        }
    }

    static func normalizedStoredServerConfig(
        _ serverConfig: UserPreferencesStorage.ServerConfig
    ) -> UserPreferencesStorage.ServerConfig {
        // Preserve historical zcash-infra hosts as manual/custom selections.
        if serverConfig.host.hasSuffix(".zcash-infra.com") {
            return UserPreferencesStorage.ServerConfig(
                host: serverConfig.host,
                port: serverConfig.port,
                isCustom: true
            )
        }

        return serverConfig
    }

    private static func migrationServerConfig(
        _ serverConfig: UserPreferencesStorage.ServerConfig,
        network: NetworkType
    ) -> UserPreferencesStorage.ServerConfig {
        let normalizedServer = normalizedStoredServerConfig(serverConfig)
        guard !normalizedServer.isCustom else {
            return normalizedServer
        }

        let defaultEndpoint = defaultEndpoint(for: network)
        if normalizedServer.host == defaultEndpoint.host && normalizedServer.port == defaultEndpoint.port {
            return normalizedServer
        }

        if isKnownEndpoint(host: normalizedServer.host, port: normalizedServer.port, network: network) {
            return normalizedServer
        }

        return UserPreferencesStorage.ServerConfig(
            host: normalizedServer.host,
            port: normalizedServer.port,
            isCustom: true
        )
    }

    private static func shouldPreserveAsManualSelection(
        _ serverConfig: UserPreferencesStorage.ServerConfig,
        network: NetworkType
    ) -> Bool {
        if serverConfig.isCustom {
            return true
        }

        let defaultEndpoint = defaultEndpoint(for: network)
        if serverConfig.host == defaultEndpoint.host && serverConfig.port == defaultEndpoint.port {
            return false
        }

        return true
    }

    static func storedServerConfig() -> UserPreferencesStorage.ServerConfig? {
        @Dependency(\.userStoredPreferences) var userStoredPreferences
        return userStoredPreferences.server()
    }
}
