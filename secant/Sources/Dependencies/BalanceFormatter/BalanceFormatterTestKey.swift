//
//  BalanceFormatterTestKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 14.11.2022.
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension BalanceFormatterClient {
    static let noOp = Self(
        convert: { _, _, _ in .placeholer }
    )
}
