//
//  ToolbarAction.swift
//  
//
//  Created by Lukáš Korba on 19.10.2023.
//

import SwiftUI

struct ToolbarActionModifier<ToolbarActionContent>: ViewModifier where ToolbarActionContent: View {
    @ViewBuilder let toolbarActionContent: ToolbarActionContent
    
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    toolbarActionContent
                }
            }
    }
}

extension View {
    func toolbarAction(_ content: () -> some View) -> some View {
        modifier(ToolbarActionModifier(toolbarActionContent: content))
    }
}
