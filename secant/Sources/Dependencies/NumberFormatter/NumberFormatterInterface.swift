//
//  NumberFormatterInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.11.2022.
//

import Foundation
import ComposableArchitecture

extension DependencyValues {
    var numberFormatter: NumberFormatterClient {
        get { self[NumberFormatterClient.self] }
        set { self[NumberFormatterClient.self] = newValue }
    }
}

@DependencyClient
struct NumberFormatterClient {
    var string: @Sendable (NSDecimalNumber) -> String? = { _ in nil }
    var number: @Sendable (String) -> NSNumber? = { _ in nil }
    var convertUSToLocale: @Sendable (String) -> String? = { _ in nil }
}
