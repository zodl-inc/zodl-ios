//
//  ScreenHorizontalPadding.swift
//
//
//  Created by Lukáš Korba on 16.09.2024.
//

import SwiftUI

struct ScreenHorizontalPaddingModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 24)
    }
}

extension View {
    func screenHorizontalPadding() -> some View {
        self.modifier(
            ScreenHorizontalPaddingModifier()
        )
    }
}
