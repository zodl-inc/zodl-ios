//
//  BalanceWithIconView.swift
//
//
//  Created by Lukáš Korba on 19.10.2023.
//

import SwiftUI
@preconcurrency import ZcashLightClientKit

struct BalanceWithIconView: View {
    let balance: Zatoshi
    let couldBeHidden: Bool
    
    init(balance: Zatoshi, couldBeHidden: Bool = false) {
        self.balance = balance
        self.couldBeHidden = couldBeHidden
    }
    
    var body: some View {
        HStack(spacing: 0) {
            ZcashSymbol()
                .frame(width: 32, height: 32)
                .zForegroundColor(Design.Text.primary)

            ZatoshiRepresentationView(
                balance: balance,
                fontName: FontFamily.Inter.semiBold.name,
                mostSignificantFontSize: 48,
                leastSignificantFontSize: 14,
                format: .expanded,
                couldBeHidden: couldBeHidden
            )
//            Circle()
//                .frame(width: 25, height: 25)
//                .zForegroundColor(Design.Surfaces.brandPrimary)
//                .overlay {
//                    ZcashSymbol()
//                        .frame(width: 15, height: 15)
//                        .foregroundColor(Asset.Colors.secondary.color)
//                }
        }
    }
}

#Preview {
    VStack {
        BalanceWithIconView(balance: Zatoshi(25_793_456))
        
        BalanceWithIconView(balance: Zatoshi(1_4050_000))

        BalanceWithIconView(balance: Zatoshi(1_4364_000))
        
        BalanceWithIconView(balance: Zatoshi(1_000_000))

        BalanceWithIconView(balance: Zatoshi(98_000))

        BalanceWithIconView(balance: Zatoshi(0))
    }
}
