//
//  InsufficientFundsSheet.swift
//  Zashi
//
//  Created by Lukáš Korba on 12-10-2025.
//

import SwiftUI

struct InsufficientFundsSheetModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .zashiSheet(isPresented: $isPresented) {
                VStack(alignment: .leading, spacing: 0) {
                    Asset.Assets.infoOutline.image
                        .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                        .background {
                            Circle()
                                .fill(Design.Utility.ErrorRed._50.color(colorScheme))
                                .frame(width: 44, height: 44)
                        }
                        .padding(.top, 48)
                        .padding(.leading, 12)

                    Text(localizable: .sheetInsufficientBalanceTitle)
                        .zFont(.semiBold, size: 24, style: Design.Text.primary)
                        .padding(.top, 24)
                        .padding(.bottom, 12)
                    
                    Text(localizable: .sheetInsufficientBalanceMsg)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                        .padding(.bottom, 32)

                    ZashiButton(String(localizable: .generalOk).uppercased()) {
                        isPresented = false
                    }
                    .padding(.bottom, Design.Spacing.sheetBottomSpace)
                }
            }
    }
}

extension View {
    func insufficientFundsSheet(isPresented: Binding<Bool>) -> some View {
        modifier(
            InsufficientFundsSheetModifier(isPresented: isPresented)
        )
    }
}
