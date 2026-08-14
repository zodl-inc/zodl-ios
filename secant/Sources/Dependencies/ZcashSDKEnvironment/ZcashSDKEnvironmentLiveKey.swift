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
            ironwoodActivationHeight: {
                switch network.networkType {
                case .mainnet, .testnet:
                    // The SDK (`ZcashNetwork.ironwoodActivationHeight`, backed by zcash_protocol) is
                    // the single source of truth for the NU6.3 (Ironwood) activation height on
                    // mainnet/testnet — the hand-mirrored constants this replaces are gone. The nil
                    // branch never actually occurs for these two network types, but is still handled
                    // fail-closed.
                    return network.ironwoodActivationHeight ?? BlockHeight.max
                case .regtest:
                    // Custom/regtest network: read the configured NU6.3 height, or "never activated" if absent.
                    return network.customActivationHeights?.nu6_3 ?? BlockHeight.max
                }
            },
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
        migrateDecommissionedServersIfNeeded(for: network)
        initializeAutomaticServerSelectionIfNeeded(for: network)

        guard let serverConfig = storedServerConfig() else {
            return defaultEndpoint(for: network).serverConfig()
        }

        return normalizedStoredServerConfig(serverConfig)
    }

    /// Historical `*.zcash-infra.com` hosts are treated as custom (manual) selections.
    static func normalizedStoredServerConfig(
        _ serverConfig: UserPreferencesStorage.ServerConfig
    ) -> UserPreferencesStorage.ServerConfig {
        if serverConfig.host.hasSuffix(".zcash-infra.com") {
            return UserPreferencesStorage.ServerConfig(host: serverConfig.host, port: serverConfig.port, isCustom: true)
        }
        return serverConfig
    }

    /// One-time initialization of the Automatic/Manual flag based on the user's existing server:
    /// - no stored server, or any non-custom server (the default, a known list server, or a legacy
    ///   built-in host) -> Automatic
    /// - only a user-entered custom server -> Manual (preserve the explicit choice)
    static func initializeAutomaticServerSelectionIfNeeded(for network: NetworkType) {
        @Dependency(\.userStoredPreferences) var userStoredPreferences

        guard userStoredPreferences.automaticServerSelection() == nil else { return }

        // Automatic unless the user explicitly entered a custom server. Keyed off the raw stored
        // `isCustom` flag (not the display-normalized one) so legacy built-in hosts such as
        // *.zcash-infra.com -- stored non-custom but normalized to "custom" for the Server Setup UI --
        // still migrate to Automatic. Only a user-typed custom host stays on Manual.
        let enableAutomatic = userStoredPreferences.server()?.isCustom != true

        userStoredPreferences.setAutomaticServerSelection(enableAutomatic)
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
    
    static func migrateDecommissionedServersIfNeeded(for network: NetworkType) {
        @Dependency(\.userStoredPreferences) var userStoredPreferences

        // Intentionally kept separate from `endpoints(...)`: these hosts have been removed from the
        // endpoint list, and we migrate any user whose stored server matches one of these exact
        // "host:port" values precisely because the server no longer appears there. Add future
        // decommissioned servers here as "host:port".
        let decommissionedServers: Set<String> = [
            "eu2.zec.stardust.rest:443",
            "jp.zec.stardust.rest:443"
        ]

        guard let serverConfig = userStoredPreferences.server() else { return }

        if decommissionedServers.contains(serverConfig.serverString()) {
            let defaultConfig = defaultEndpoint(for: network).serverConfig()
            try? userStoredPreferences.setServer(defaultConfig)
        }
    }

    static func storedServerConfig() -> UserPreferencesStorage.ServerConfig? {
        @Dependency(\.userStoredPreferences) var userStoredPreferences
        return userStoredPreferences.server()
    }
}
