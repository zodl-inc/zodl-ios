//
//  ListBackground.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-11-28.
//

import SwiftUI

struct ListBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets())
            .listRowBackground(Asset.Colors.background.color)
            .listRowSeparator(.hidden)
    }
}

extension View {
    func listBackground() -> some View {
        self.modifier(
            ListBackgroundModifier()
        )
    }
}
