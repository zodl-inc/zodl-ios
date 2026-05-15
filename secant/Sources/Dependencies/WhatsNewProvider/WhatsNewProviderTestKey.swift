//
//  WhatsNewProviderTestKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-14-2024.
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension WhatsNewProviderClient {
    static let noOp = Self(
        latest: { .zero },
        all: { .zero }
    )
}
