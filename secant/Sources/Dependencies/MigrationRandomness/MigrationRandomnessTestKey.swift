//
//  MigrationRandomnessTestKey.swift
//  Zashi
//

import ComposableArchitecture

extension MigrationRandomnessClient: TestDependencyKey {
    static let testValue = MigrationRandomnessClient(randomIndex: { _ in 0 })
}
