//
//  ZcashSDKEnvironmentInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 13.11.2022.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var zcashSDKEnvironment: ZcashSDKEnvironment {
        get { self[ZcashSDKEnvironment.self] }
        set { self[ZcashSDKEnvironment.self] = newValue }
    }
}

extension ZcashSDKEnvironment {
    enum ZcashSDKConstants {
        static let endpointMainnetAddress = "zec.rocks"
        static let endpointTestnetAddress = "testnet.zec.rocks"
        static let endpointMainnetPort = 443
        static let endpointTestnetPort = 443
        static let mnemonicWordsMaxCount = 24
        static let requiredTransactionConfirmations = 10
        static let streamingCallTimeoutInMillis = Int64(10 * 60 * 60 * 1000) // ten hours
    }
    
    enum Server: Equatable, Hashable {
        case custom
        case `default`
        case hardcoded(String)
        
        func desc(for network: NetworkType) -> String? {
            var value: String?
            
            if case .default = self {
                value = String(localizable: .serverSetupDefault)
            }
            
            return value
        }
        
        func value(for network: NetworkType) -> String {
            switch self {
            case .custom:
                return String(localizable: .serverSetupCustom)
            case .default:
                return defaultEndpoint(for: network).server()
            case .hardcoded(let value):
                return value
            }
        }
    }

    static func servers(for network: NetworkType) -> [Server] {
        var servers = [Server.default]

        if network == .mainnet {
            servers.append(.custom)
            
            let mainnetServers = ZcashSDKEnvironment.endpoints(for: network, skipDefault: true).map {
                Server.hardcoded("\($0.host):\($0.port)")
            }
            
            servers.append(contentsOf: mainnetServers)
        } else if network == .testnet {
            servers.append(.custom)
        }
        
        return servers
    }
    
    static func defaultEndpoint(for network: NetworkType) -> LightWalletEndpoint {
        let defaultHost = network == .mainnet ? ZcashSDKConstants.endpointMainnetAddress : ZcashSDKConstants.endpointTestnetAddress
        let defaultPort = network == .mainnet ? ZcashSDKConstants.endpointMainnetPort : ZcashSDKConstants.endpointTestnetPort

        return LightWalletEndpoint(
            address: defaultHost,
            port: defaultPort,
            secure: true,
            streamingCallTimeoutInMillis: ZcashSDKConstants.streamingCallTimeoutInMillis
        )
    }
    
    static func endpoints(for network: NetworkType, skipDefault: Bool = false) -> [LightWalletEndpoint] {
        // Testnet has a single endpoint, so there is nothing to benchmark.
        if network == .testnet {
            return skipDefault ? [] : [defaultEndpoint(for: network)]
        }

        let timeout = ZcashSDKConstants.streamingCallTimeoutInMillis
        var result: [LightWalletEndpoint] = []

        if !skipDefault {
            result.append(defaultEndpoint(for: network))
        }

        result.append(
            contentsOf: [
                LightWalletEndpoint(address: "na.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: timeout),
                LightWalletEndpoint(address: "sa.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: timeout),
                LightWalletEndpoint(address: "eu.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: timeout),
                LightWalletEndpoint(address: "ap.zec.rocks", port: 443, secure: true, streamingCallTimeoutInMillis: timeout),
                LightWalletEndpoint(address: "us.zec.stardust.rest", port: 443, secure: true, streamingCallTimeoutInMillis: timeout),
                LightWalletEndpoint(address: "eu.zec.stardust.rest", port: 443, secure: true, streamingCallTimeoutInMillis: timeout)
            ]
        )

        return result
    }
}

@DependencyClient
struct ZcashSDKEnvironment {
    var latestCheckpoint: @Sendable () -> BlockHeight = { 0 }
    var endpoint: @Sendable () -> LightWalletEndpoint = {
        LightWalletEndpoint(address: "", port: 0, secure: false, singleCallTimeoutInMillis: 0, streamingCallTimeoutInMillis: 0)
    }
    var exchangeRateIPRateLimit: @Sendable () -> TimeInterval = { 0 }
    var exchangeRateStaleLimit: @Sendable () -> TimeInterval = { 0 }
    /// The height at which the Ironwood (NU6.3) network upgrade activates on the current network.
    /// `BlockHeight.max` is a deliberate fail-closed default: an unknown network is treated as
    /// "Ironwood never activates" rather than "Ironwood already activated".
    var ironwoodActivationHeight: @Sendable () -> BlockHeight = { BlockHeight.max }
    var memoCharLimit: @Sendable () -> Int = { 0 }
    var mnemonicWordsMaxCount: @Sendable () -> Int = { 0 }
    var network: @Sendable () -> ZcashNetwork = { ZcashNetworkBuilder.network(for: .testnet) }
    var requiredTransactionConfirmations: @Sendable () -> Int = { 0 }
    var sdkVersion: @Sendable () -> String = { "" }
    var serverConfig: @Sendable () -> UserPreferencesStorage.ServerConfig = { UserPreferencesStorage.ServerConfig(host: "", port: 0, isCustom: false) }
    var servers: @Sendable () -> [Server] = { [] }
    var shieldingThreshold: @Sendable () -> Zatoshi = { Zatoshi(0) }
    var tokenName: @Sendable () -> String = { "" }
}

extension LightWalletEndpoint {
    func server() -> String {
        "\(self.host):\(self.port)"
    }
    
    func serverConfig(isCustom: Bool = false) -> UserPreferencesStorage.ServerConfig {
        UserPreferencesStorage.ServerConfig(host: host, port: port, isCustom: isCustom)
    }
}
