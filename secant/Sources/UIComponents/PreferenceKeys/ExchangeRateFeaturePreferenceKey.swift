//
//  ExchangeRateFeaturePreferenceKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 08-12-2024.
//

import SwiftUI

struct ExchangeRateFeaturePreferenceKey: PreferenceKey {
    typealias Value = Anchor<CGRect>?

    static var defaultValue: Value = nil

    static func reduce(
        value: inout Value,
        nextValue: () -> Value
    ) {
        value = nextValue() ?? value
    }
}
