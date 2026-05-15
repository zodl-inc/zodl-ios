//
//  InfoRow.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-11-26.
//

import SwiftUI

struct InfoRow: View {
    @Environment(\.colorScheme) private var colorScheme
    
    let icon: Image
    let title: String
    
    init(
        icon: Image,
        title: String
    ) {
        self.icon = icon
        self.title = title
    }
    
    var body: some View {
        HStack(spacing: 0) {
            icon
                .zImage(size: 20, style: Design.Text.primary)
                .padding(10)
                .background {
                    Circle()
                        .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                }
                .padding(.trailing, 16)
            
            Text(title)
                .zFont(.semiBold, size: 16, style: Design.Text.primary)

            Spacer(minLength: 2)
        }
        .background(Asset.Colors.background.color)
    }
}
