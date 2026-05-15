//
//  FeedbackGeneratorInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 14.11.2022.
//

import ComposableArchitecture

extension DependencyValues {
    var feedbackGenerator: FeedbackGeneratorClient {
        get { self[FeedbackGeneratorClient.self] }
        set { self[FeedbackGeneratorClient.self] = newValue }
    }
}

@DependencyClient
struct FeedbackGeneratorClient {
    var generateSuccessFeedback: @Sendable () async -> Void = { }
    var generateWarningFeedback: @Sendable () async -> Void = { }
    var generateErrorFeedback: @Sendable () async -> Void = { }
}
