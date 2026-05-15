//
//  UserDefaultsTestKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 13.11.2022.
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension UserDefaultsClient {
    static let noOp = Self(
        objectForKey: { _ in nil },
        remove: { _ in },
        setValue: { _, _ in }
    )
}
