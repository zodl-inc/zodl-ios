//
//  AutoServerSelectionTestKey.swift
//  Zashi
//

import ComposableArchitecture

extension AutoServerSelectionClient: TestDependencyKey {
    static let testValue = AutoServerSelectionClient(
        findBestServer: { nil },
        applySwitch: { _ in false }
    )
}
