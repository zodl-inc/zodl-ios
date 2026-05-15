//
//  AutolockHandlerTestKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 06-10-2024.
//

import Foundation
import ComposableArchitecture
import XCTestDynamicOverlay

extension AutolockHandlerClient {
    static let noOp = Self(
        value: { _ in },
        batteryStatePublisher: { NotificationCenter.Publisher(center: .default, name: Notification.Name(rawValue: "noOp")) }
    )
}
