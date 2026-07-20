//
//  MigrationRandomnessLiveKey.swift
//  Zashi
//

import ComposableArchitecture
import Foundation

extension MigrationRandomnessClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            randomIndex: { count in
                var generator = SystemRandomNumberGenerator()
                return Int.random(in: 0..<count, using: &generator)
            }
        )
    }
}
