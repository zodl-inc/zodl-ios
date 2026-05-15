//
//  DateClient.swift
//  Zashi
//
//  Created by Lukáš Korba on 04.04.2023.
//

import Foundation
import ComposableArchitecture

extension DependencyValues {
    var date: DateClient {
        get { self[DateClient.self] }
        set { self[DateClient.self] = newValue }
    }
}

@DependencyClient
struct DateClient {
    var now: @Sendable () -> Date = { Date() }
}
