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
            .navigationBarTitleDisplayMode(.inline)
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
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(text.uppercased())
                        .zFont(.semiBold, size: 16, style: Design.Text.primary)
                        .fixedSize()
                }
            }
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
