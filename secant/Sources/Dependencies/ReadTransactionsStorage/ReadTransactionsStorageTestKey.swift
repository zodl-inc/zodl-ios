//
//  ReadTransactionsStorageTestKey.swift
//  
//
//  Created by Lukáš Korba on 11.11.2023.
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension ReadTransactionsStorageClient {
    static let noOp = Self(
        markIdAsRead: { _ in },
        readIds: { [:] },
        availabilityTimestamp: { 0 },
        resetZashi: { }
    )
}
