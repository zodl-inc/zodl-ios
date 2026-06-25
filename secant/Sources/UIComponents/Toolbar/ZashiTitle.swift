//
//  ZashiTitle.swift
//
//
//  Created by Lukáš Korba on 06.10.2023.
//

import SwiftUI

struct ZashiTitleModifier<ZashiTitleContent>: ViewModifier where ZashiTitleContent: View {
    @ViewBuilder let zashiTitleContent: ZashiTitleContent
    
    func body(content: Content) -> some View {
#if os(macOS)
        // macOS wraps principal toolbar items in a liquid-glass bubble; skip it (see ScreenTitle). Set an
        // EMPTY navigationTitle so the next pushed screen's native back button shows just the chevron, not
        // the window-title fallback ("← Zodl") — the Beta back labels are non-contextual, so drop them.
        content
            .navigationTitle("")
#else
        content
            .zashiNavBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    zashiTitleContent
                }
            }
#endif
    }
}

struct ScreenTitleModifier: ViewModifier {
    let text: String
    
    func body(content: Content) -> some View {
#if os(macOS)
        // macOS auto-wraps principal toolbar items in a liquid-glass bubble, which looks wrong for a plain
        // screen title, so we don't render it. But set an EMPTY navigationTitle so the native back button on
        // the next pushed screen shows just the chevron, not the window-title fallback ("← Zodl"). Beta
        // back labels are non-contextual; drop them everywhere screenTitle is used.
        content
            .navigationTitle("")
#else
        content
            .zashiNavBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(text.uppercased())
                        .zFont(.semiBold, size: 16, style: Design.Text.primary)
                        .fixedSize()
                }
            }
#endif
    }
}

extension View {
    func zashiTitle(_ content: () -> some View) -> some View {
        modifier(ZashiTitleModifier(zashiTitleContent: content))
    }
    
    func screenTitle(_ text: String) -> some View {
        modifier(ScreenTitleModifier(text: text))
    }
}
