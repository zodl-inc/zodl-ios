//
//  ReviewRequestInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 3.4.2023.
//

import ComposableArchitecture

extension DependencyValues {
    var reviewRequest: ReviewRequestClient {
        get { self[ReviewRequestClient.self] }
        set { self[ReviewRequestClient.self] = newValue }
    }
}

@DependencyClient
struct ReviewRequestClient {
    var canRequestReview: @Sendable () -> Bool = { false }
    var foundTransactions: @Sendable () -> Void
    var reviewRequested: @Sendable () -> Void
    var syncFinished: @Sendable () -> Void
}
