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
        content
            .zashiNavBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    zashiTitleContent
                }
            }
    }
}

struct ScreenTitleModifier: ViewModifier {
    let text: String
    
    func body(content: Content) -> some View {
#if os(macOS)
        // macOS auto-wraps principal toolbar items in a liquid-glass bubble, which looks wrong for
        // a plain screen title. Drop it on macOS — content screens carry their own headers.
        content
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
