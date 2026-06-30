//
//  UserPreferencesStorage.swift
//  Zashi
//
//  Created by Lukáš Korba on 03/18/2022.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// Live implementation of the `UserPreferences` using User Defaults
/// according to https://developer.apple.com/documentation/foundation/userdefaults
/// the UserDefaults class is thread-safe.
struct UserPreferencesStorage {
    enum Constants: String, CaseIterable {
        /// 2.4.9 forced all users to re-enable exchange rate setup.
        /// Previous key `ups_exchangeRate` is `legacy` one and present here only for purpose of removal.
        case ups_exchangeRate
        /// The current key for exchange rate setup.
        case ups_exchangeRate2
        case ups_server
        case ups_automaticServerSelection
    }

    enum UserPreferencesStorageError: Error {
        case exchangeRate
        case serverConfig
    }
    
    /// Default values for all preferences in case there is no value stored (counterparts to `Constants`)
    private let defaultExchangeRate: Data
    private let defaultServer: Data

    private let userDefaults: UserDefaultsClient
    
    init(
        defaultExchangeRate: Data,
        defaultServer: Data,
        userDefaults: UserDefaultsClient
    ) {
        self.defaultExchangeRate = defaultExchangeRate
        self.defaultServer = defaultServer
        self.userDefaults = userDefaults
    }
    
    /// From when the app is on and uninterrupted
    var server: ServerConfig? {
        let contentData = getValue(forKey: Constants.ups_server.rawValue, default: defaultServer)

        if let content = try? JSONDecoder().decode(ServerConfig.self, from: contentData) {
            return content
        }
        
        return nil
    }
    
    func setServer(_ server: ServerConfig) throws {
        do {
            let contentData = try JSONEncoder().encode(server)
            setValue(contentData, forKey: Constants.ups_server.rawValue)
        } catch {
            throw UserPreferencesStorageError.serverConfig
        }
    }

    /// Whether the app automatically benchmarks known servers and keeps the fastest one.
    /// `nil` means the preference has never been set (first run) — used by migration.
    var automaticServerSelection: Bool? {
        userDefaults.objectForKey(Constants.ups_automaticServerSelection.rawValue) as? Bool
    }

    func setAutomaticServerSelection(_ enabled: Bool) {
        setValue(enabled, forKey: Constants.ups_automaticServerSelection.rawValue)
    }

    /// Exchange rate API in the SDK uses TOR and eventually fetches the data from rate providers. This has to be opted in by a user, by default it's off.
    var exchangeRate: ExchangeRate? {
        /// Removal of `legacy` key, see the comment of `Constants.ups_exchangeRate`
        if userDefaults.objectForKey(Constants.ups_exchangeRate.rawValue) != nil {
            userDefaults.remove(Constants.ups_exchangeRate.rawValue)
        }

        let contentData = getValue(forKey: Constants.ups_exchangeRate2.rawValue, default: defaultExchangeRate)

        if let content = try? JSONDecoder().decode(ExchangeRate.self, from: contentData) {
            return content
        }
        
        return nil
    }
    
    func setExchangeRate(_ newValue: ExchangeRate?) throws -> Void {
        do {
            let contentData = try JSONEncoder().encode(newValue)
            setValue(contentData, forKey: Constants.ups_exchangeRate2.rawValue)
        } catch {
            throw UserPreferencesStorageError.exchangeRate
        }
    }

    /// Use carefully: Deletes all user preferences from the User Defaults
    func removeAll() {
        for key in Constants.allCases {
            userDefaults.remove(key.rawValue)
        }
    }
}

private extension UserPreferencesStorage {
    func getValue<Value>(forKey: String, default defaultIfNil: Value) -> Value {
        userDefaults.objectForKey(forKey) as? Value ?? defaultIfNil
    }

    func setValue<Value>(_ value: Value, forKey: String) {
        userDefaults.setValue(value, forKey)
    }
}

// MARK: Exchange Rate

extension UserPreferencesStorage {
    struct ExchangeRate: Equatable, Codable {
        let manual: Bool
        let automatic: Bool
        let currency: CurrencyISO4217

        init(manual: Bool, automatic: Bool, currency: CurrencyISO4217 = .usd) {
            self.manual = manual
            self.automatic = automatic
            self.currency = currency
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            manual = try container.decode(Bool.self, forKey: .manual)
            automatic = try container.decode(Bool.self, forKey: .automatic)
            currency = try container.decodeIfPresent(CurrencyISO4217.self, forKey: .currency) ?? .usd
        }
    }
}

// MARK: Server Config

extension UserPreferencesStorage {
    struct ServerConfig: Equatable, Codable {
        let host: String
        let port: Int
        let isCustom: Bool
        
        init(host: String, port: Int, isCustom: Bool) {
            self.host = host
            self.port = port
            self.isCustom = isCustom
        }
        
        func serverString() -> String {
            "\(host):\(port)"
        }
        
        func endpoint(streamingCallTimeoutInMillis: Int64) -> LightWalletEndpoint {
            LightWalletEndpoint(
                address: host,
                port: port,
                secure: true,
                streamingCallTimeoutInMillis: streamingCallTimeoutInMillis
            )
        }
        
        static func endpoint(for string: String, streamingCallTimeoutInMillis: Int64) -> LightWalletEndpoint? {
            // remove http:// or https:// from the input if present
            var input = string
            
            let http = "http://"
            let https = "https://"
            if input.contains(https) {
                input = String(input.dropFirst(https.count))
            } else if input.contains(http) {
                input = String(input.dropFirst(http.count))
            }
            
            // Split on the LAST colon: everything after it is the port, everything before
            // it is the host taken verbatim. This preserves any colons the host legitimately
            // contains (e.g. IPv6) and never re-introduces a duplicate separator.
            guard let separatorIndex = input.lastIndex(of: ":") else {
                return nil
            }

            let host = String(input[..<separatorIndex])
            let portString = input[input.index(after: separatorIndex)...]

            guard !host.isEmpty, let port = Int(portString) else {
                return nil
            }

            return LightWalletEndpoint(
                address: host,
                port: port,
                secure: true,
                streamingCallTimeoutInMillis: streamingCallTimeoutInMillis
            )
        }
        
        static func config(for string: String, isCustom: Bool, streamingCallTimeoutInMillis: Int64) -> ServerConfig? {
            guard let endpoint = ServerConfig.endpoint(for: string, streamingCallTimeoutInMillis: streamingCallTimeoutInMillis) else {
                return nil
            }

            return ServerConfig(host: endpoint.host, port: endpoint.port, isCustom: isCustom)
        }
    }
}

// MARK: Connection Mode

extension UserPreferencesStorage {
    /// UI-facing connection mode for Server Setup. Persisted as the `automaticServerSelection` boolean
    /// (`.automatic` == `true`); this enum exists so the two-mode picker reads clearly.
    enum ConnectionMode: String, Codable, Equatable {
        case automatic
        case manual
    }
}
