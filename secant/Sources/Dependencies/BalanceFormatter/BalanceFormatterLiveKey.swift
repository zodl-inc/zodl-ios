//
//  BalanceFormatterLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 14.11.2022.
//

import Foundation
import ComposableArchitecture

extension BalanceFormatterClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        return Self(
            convert: { ZatoshiStringRepresentation($0, prefixSymbol: $1, format: $2) }
        )
    }
}
