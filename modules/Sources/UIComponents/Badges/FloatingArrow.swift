//
//  FloatingArrow.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-06-24.
//

import SwiftUI

import Generated

public struct FloatingArrow: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() { }
    
    public var body: some View {
        Asset.Assets.Icons.arrowRight.image
            .zImage(size: 16, style: Design.Text.tertiary)
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: Design.Spacing._md)
                    .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                    .frame(width: 32, height: 32)
            }
            .shadow(color: .black.opacity(0.02), radius: 0.66667, x: 0, y: 1.33333)
            .shadow(color: .black.opacity(0.08), radius: 1.33333, x: 0, y: 1.33333)
    }
}
