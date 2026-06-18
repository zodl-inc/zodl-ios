//
//  PlatformPresentation.swift
//  Zashi
//
//  Cross-platform shims for presentation/navigation modifiers that are iOS-only.
//  iOS keeps its exact behavior; macOS falls back to the nearest native equivalent.
//

import SwiftUI

extension View {
    @ViewBuilder
    func zashiNavigationBarHidden(_ hidden: Bool) -> some View {
#if os(iOS)
        navigationBarHidden(hidden)
#else
        self // macOS: no navigation bar to hide
#endif
    }

    func zashiFullScreenCover<C: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> C
    ) -> some View {
#if os(iOS)
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
#else
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
#endif
    }

    func zashiFullScreenCover<Item: Identifiable, C: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> C
    ) -> some View {
#if os(iOS)
        fullScreenCover(item: item, onDismiss: onDismiss, content: content)
#else
        sheet(item: item, onDismiss: onDismiss, content: content)
#endif
    }
}
