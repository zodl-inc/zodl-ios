//
//  CaptureDeviceTestKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 11.11.2022.
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension CaptureDeviceClient {
    static let noOp = Self(
        isAuthorized: { false },
        isTorchAvailable: { false },
        torch: { _ in }
    )
}
