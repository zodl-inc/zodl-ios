//
//  FeedbackGeneratorLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 14.11.2022.
//

import UIKit
import ComposableArchitecture

extension FeedbackGeneratorClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            generateSuccessFeedback: { @MainActor in UINotificationFeedbackGenerator().notificationOccurred(.success) },
            generateWarningFeedback: { @MainActor in UINotificationFeedbackGenerator().notificationOccurred(.warning) },
            generateErrorFeedback: { @MainActor in UINotificationFeedbackGenerator().notificationOccurred(.error) }
        )
    }
}
