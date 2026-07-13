//
//  AutolockHandlerInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 06-10-2024.
//

import ComposableArchitecture
import Foundation

extension DependencyValues {
    var autolockHandler: AutolockHandlerClient {
        get { self[AutolockHandlerClient.self] }
        set { self[AutolockHandlerClient.self] = newValue }
    }
}

@DependencyClient
struct AutolockHandlerClient {
    var value: @Sendable (Bool) async -> Void = { _ in }
    var batteryStatePublisher: @Sendable () -> NotificationCenter.Publisher = {
        NotificationCenter.Publisher(center: .default, name: Notification.Name("co.zodl.autolock.placeholder"))
    }
}
