//
//  BluetoothPermissionTestKey.swift
//  Zashi
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension BluetoothPermissionClient {
    static let noOp = Self(
        authorizationStatus: { .notDetermined },
        requestAuthorization: { }
    )
}
