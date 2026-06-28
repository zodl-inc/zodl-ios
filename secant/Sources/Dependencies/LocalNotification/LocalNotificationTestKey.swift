//
//  LocalNotificationTestKey.swift
//  zodl
//

import ComposableArchitecture

extension LocalNotificationClient {
    static let noOp = LocalNotificationClient(
        requestAuthorization: { true },
        post: { _, _, _ in },
        removeAll: { }
    )
}
