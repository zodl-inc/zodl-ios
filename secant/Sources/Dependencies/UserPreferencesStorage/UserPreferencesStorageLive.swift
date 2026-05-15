//
//  UserPreferencesStorageLive.swift
//  Zashi
//
//  Created by Lukáš Korba on 15.11.2022.
//

import Foundation
import ComposableArchitecture

extension UserPreferencesStorageClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        let live = UserPreferencesStorage.live

        return UserPreferencesStorageClient(
            server: { live.server },
            setServer: { try live.setServer($0) },
            exchangeRate: { live.exchangeRate },
            setExchangeRate: { try live.setExchangeRate($0) },
            removeAll: { live.removeAll() }
        )
    }
}

extension UserPreferencesStorage {
    static let live = UserPreferencesStorage(
        defaultExchangeRate: Data(),
        defaultServer: Data(),
        userDefaults: .live()
    )
}
