//
//  SwiftUIView.swift
//  
//
//  Created by Lukáš Korba on 10.11.2023.
//

import SwiftUI
import ComposableArchitecture

@preconcurrency import ZcashLightClientKit

struct AvailableBalanceView: View {
    @Environment(\.colorScheme) var colorScheme
    
    let balance: Zatoshi
    let showIndicator: Bool

    init(
        balance: Zatoshi,
        showIndicator: Bool = false
    ) {
        self.balance = balance
        self.showIndicator = showIndicator
    }
    
    var body: some View {
        HStack(spacing: 0) {
            Asset.Assets.Icons.expand.image
                .zImage(size: 16, style: Design.Text.tertiary)
                .padding(.trailing, 4)
            
            Text(localizable: .balanceAvailableTitle)
                .zFont(.semiBold, size: 14, style: Design.Btns.Tertiary.fg)
                .padding(.trailing, 6)

            if showIndicator {
                ProgressView()
                    .scaleEffect(0.9)
            } else {
                HStack(spacing: 0) {
                    ZcashSymbol()
                        .frame(width: 12, height: 12)
                        .zForegroundColor(Design.Text.tertiary)
                    
                    ZatoshiText(balance)
                        .zFont(.semiBold, size: 14, style: Design.Btns.Tertiary.fg)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._lg)
                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._lg)
                        .stroke(Design.Utility.Gray._100.color(colorScheme))
                }
        }
        .shadow(color: .black.opacity(0.02), radius: 0.66667, x: 0, y: 1.33333)
        .shadow(color: .black.opacity(0.08), radius: 1.33333, x: 0, y: 1.33333)
    }
}

#Preview {
    AvailableBalanceView(balance: Zatoshi(25_793_456), showIndicator: true)
}
