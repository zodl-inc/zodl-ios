//
//  QRImageDetectorTestKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-04-18.
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension QRImageDetectorClient {
    static let noOp = Self(
        check: { _ in nil }
    )
}
