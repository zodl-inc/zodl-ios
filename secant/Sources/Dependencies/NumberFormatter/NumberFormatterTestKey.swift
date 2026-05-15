//
//  NumberFormatterTestKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 14.11.2022.
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension NumberFormatterClient {
    static let noOp = Self(
        string: { _ in nil },
        number: { _ in nil },
        convertUSToLocale: { _ in nil }
    )
}
