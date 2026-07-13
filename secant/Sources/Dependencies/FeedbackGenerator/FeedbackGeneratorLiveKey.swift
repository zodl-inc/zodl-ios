//
//  FeedbackGeneratorLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 14.11.2022.
//

#if canImport(UIKit)
import UIKit
#endif
import ComposableArchitecture

extension FeedbackGeneratorClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
#if canImport(UIKit)
        Self(
            generateSuccessFeedback: { @MainActor in UINotificationFeedbackGenerator().notificationOccurred(.success) },
            generateWarningFeedback: { @MainActor in UINotificationFeedbackGenerator().notificationOccurred(.warning) },
            generateErrorFeedback: { @MainActor in UINotificationFeedbackGenerator().notificationOccurred(.error) }
        )
#else
        Self(
            generateSuccessFeedback: { @MainActor in },
            generateWarningFeedback: { @MainActor in },
            generateErrorFeedback: { @MainActor in }
        )
#endif
    }
}
