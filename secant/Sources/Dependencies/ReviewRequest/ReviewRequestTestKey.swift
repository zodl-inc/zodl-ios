//
//  ReviewRequestTestKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 3.4.2023.
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension ReviewRequestClient {
    static let noOp = Self(
        canRequestReview: { false },
        foundTransactions: { },
        reviewRequested: { },
        syncFinished: { }
    )
}
