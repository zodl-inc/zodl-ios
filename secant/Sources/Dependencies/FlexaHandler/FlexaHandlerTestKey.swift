//
//  FlexaHandlerTestKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 03-09-2024
//

import ComposableArchitecture
import XCTestDynamicOverlay
@preconcurrency import Combine

extension FlexaHandlerClient {
    static let noOp = Self(
        prepare: { },
        open: { },
        onTransactionRequest: { Empty().eraseToAnyPublisher() },
        clearTransactionRequest: { },
        transactionSent: { _, _ in },
        updateBalance: { _, _ in },
        flexaAlert: { _, _ in },
        signOut: { }
    )
}
