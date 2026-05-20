//
//  DateLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 04.04.2023.
//

import Foundation
import ComposableArchitecture

extension DateClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            now: { Date.now }
        )
    }
}
