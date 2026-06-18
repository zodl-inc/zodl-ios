//
//  KeyboardVisibilityModifier.swift
//  Zashi
//
//  Created by Lukáš Korba on 03-25-2025.
//

import SwiftUI

struct KeyboardVisibilityModifier: ViewModifier {
    @Binding var isVisible: Bool

    func body(content: Content) -> some View {
#if canImport(UIKit)
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                withAnimation { isVisible = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation { isVisible = false }
            }
#else
        content // macOS: no software keyboard to track
#endif
    }
}

extension View {
    func trackKeyboardVisibility(_ isVisible: Binding<Bool>) -> some View {
        modifier(KeyboardVisibilityModifier(isVisible: isVisible))
    }
}
