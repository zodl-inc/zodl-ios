//
//  UserPreferencesStorageMocks.swift
//  Zashi
//
//  Created by Lukáš Korba on 15.11.2022.
//

import Foundation
import ComposableArchitecture

extension UserPreferencesStorageClient: TestDependencyKey {
    static let testValue = Self.test()

    static func test() -> Self {
        let mock = UserPreferencesStorage.mock

        return UserPreferencesStorageClient(
            server: { mock.server },
            setServer: mock.setServer(_:),
            exchangeRate: { mock.exchangeRate },
            setExchangeRate: mock.setExchangeRate(_:),
            removeAll: mock.removeAll
        )
    }
}

extension UserPreferencesStorage {
    static let mock = UserPreferencesStorage(
        defaultExchangeRate: Data(),
        defaultServer: Data(),
        userDefaults: .noOp
    )
}
