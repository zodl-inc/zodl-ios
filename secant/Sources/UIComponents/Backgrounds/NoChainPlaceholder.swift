//
//  NoChainPlaceholder.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-07-03.
//

import SwiftUI

struct NoChainPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme
    let isShimmerOn: Bool
    
    init(_ isShimmerOn: Bool = false) {
        self.isShimmerOn = isShimmerOn
    }
    
    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .shimmer(isShimmerOn).clipShape(Circle())
                .frame(width: 40, height: 40)
                .zForegroundColor(Design.Surfaces.bgSecondary)
                .padding(.trailing, 16)
            
            RoundedRectangle(cornerRadius: Design.Radius._md)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                .shimmer(isShimmerOn).clipShape(RoundedRectangle(cornerRadius: 7))
                .frame(width: 86, height: 14)
            
            Spacer()
            
            RoundedRectangle(cornerRadius: Design.Radius._md)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                .shimmer(isShimmerOn).clipShape(RoundedRectangle(cornerRadius: 7))
                .frame(width: 32, height: 14)
        }
        .screenHorizontalPadding()
        .padding(.vertical, 12)
    }
}
