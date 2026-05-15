//
//  LogsHandlerTest.swift
//  Zashi
//
//  Created by Lukáš Korba on 30.01.2023.
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension LogsHandlerClient {
    static let noOp = Self(
        exportAndStoreLogs: { _, _, _ in nil }
    )
}
