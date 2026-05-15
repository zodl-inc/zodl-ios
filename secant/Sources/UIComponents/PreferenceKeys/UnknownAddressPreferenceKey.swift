//
//  UnknownAddressPreferenceKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 10-03-2024.
//

import SwiftUI

struct UnknownAddressPreferenceKey: PreferenceKey {
    typealias Value = Anchor<CGRect>?

    static var defaultValue: Value = nil

    static func reduce(
        value: inout Value,
        nextValue: () -> Value
    ) {
        value = nextValue() ?? value
    }
}
