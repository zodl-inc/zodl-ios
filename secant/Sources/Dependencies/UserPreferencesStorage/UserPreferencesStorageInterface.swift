//
//  UserPreferencesStorageInterface.swift
//  Zashi
//
//  Created by Francisco Gindre on 2/6/23.
//

import Foundation
import ComposableArchitecture

extension DependencyValues {
    var userStoredPreferences: UserPreferencesStorageClient {
        get { self[UserPreferencesStorageClient.self] }
        set { self[UserPreferencesStorageClient.self] = newValue }
    }
}

@DependencyClient
struct UserPreferencesStorageClient {
    var server: @Sendable () -> UserPreferencesStorage.ServerConfig? = { nil }
    var setServer: @Sendable (UserPreferencesStorage.ServerConfig) throws -> Void

    var exchangeRate: @Sendable () -> UserPreferencesStorage.ExchangeRate? = { nil }
    var setExchangeRate: @Sendable (UserPreferencesStorage.ExchangeRate) throws -> Void

    var removeAll: @Sendable () -> Void
}
