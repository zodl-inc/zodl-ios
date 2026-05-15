//
//  SupportDataGeneratorLiveKey.swift
//  secant
//
//  Created by Michal Fousek on 28.02.2023.
//

import ComposableArchitecture

extension SupportDataGeneratorClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            generate: { SupportDataGenerator.generate() }
        )
    }
}
