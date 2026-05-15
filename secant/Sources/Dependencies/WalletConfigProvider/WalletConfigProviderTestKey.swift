//
//  WalletConfigProviderTestKey.swift
//  secant
//
//  Created by Michal Fousek on 23.02.2023.
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension WalletConfigProviderClient {
    static let noOp = Self(
        load: { WalletConfig.initial },
        update: { _, _ in }
    )
}
