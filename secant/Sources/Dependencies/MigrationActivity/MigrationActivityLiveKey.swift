//
//  MigrationActivityLiveKey.swift
//  zodl
//

import ComposableArchitecture
import Foundation

extension MigrationActivityClient: DependencyKey {
    /// `UserDefaults` key for the persisted last-activity timestamp.
    static let storageKey = "migration.lastAppActivity"

    static let liveValue = MigrationActivityClient(
        recordActivity: {
            @Dependency(\.userDefaults) var userDefaults
            userDefaults.setValue(Date(), MigrationActivityClient.storageKey)
        },
        lastActivity: {
            @Dependency(\.userDefaults) var userDefaults
            return userDefaults.objectForKey(MigrationActivityClient.storageKey) as? Date
        }
    )
}
