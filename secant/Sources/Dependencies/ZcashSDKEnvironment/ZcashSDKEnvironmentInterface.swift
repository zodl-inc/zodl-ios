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
        static let endpointMainnetAddress = "us.zec.stardust.rest"
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
            
            let mainnetServers = ZcashSDKEnvironment.endpoints(skipDefault: true).map {
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
    
    static func endpoints(skipDefault: Bool = false) -> [LightWalletEndpoint] {
        var result: [LightWalletEndpoint] = []
        
        if !skipDefault {
            result.append(LightWalletEndpoint(address: "us.zec.stardust.rest", port: 443))
        }
        
        result.append(
            contentsOf: [
                LightWalletEndpoint(address: "eu.zec.stardust.rest", port: 443),
                LightWalletEndpoint(address: "eu2.zec.stardust.rest", port: 443),
                LightWalletEndpoint(address: "jp.zec.stardust.rest", port: 443),
                LightWalletEndpoint(address: "zec.rocks", port: 443),
                LightWalletEndpoint(address: "na.zec.rocks", port: 443),
                LightWalletEndpoint(address: "sa.zec.rocks", port: 443),
                LightWalletEndpoint(address: "eu.zec.rocks", port: 443),
                LightWalletEndpoint(address: "ap.zec.rocks", port: 443)
            ]
        )
        
        return result
    }
}

@DependencyClient
struct ZcashSDKEnvironment {
    var latestCheckpoint: BlockHeight
    let endpoint: () -> LightWalletEndpoint
    let exchangeRateIPRateLimit: TimeInterval
    let exchangeRateStaleLimit: TimeInterval
    let memoCharLimit: Int
    let mnemonicWordsMaxCount: Int
    let network: ZcashNetwork
    let requiredTransactionConfirmations: Int
    let sdkVersion: String
    let serverConfig: () -> UserPreferencesStorage.ServerConfig
    let servers: [Server]
    let shieldingThreshold: Zatoshi
    let tokenName: String
}

extension LightWalletEndpoint {
    func server() -> String {
        "\(self.host):\(self.port)"
    }
    
    func serverConfig(isCustom: Bool = false) -> UserPreferencesStorage.ServerConfig {
        UserPreferencesStorage.ServerConfig(host: host, port: port, isCustom: isCustom)
    }
}
