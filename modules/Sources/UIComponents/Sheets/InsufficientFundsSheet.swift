//
//  InsufficientFundsSheet.swift
//  Zashi
//
//  Created by Lukáš Korba on 12-10-2025.
//

import SwiftUI
import Generated

public struct InsufficientFundsSheetModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    
    @Binding public var isPresented: Bool

    public func body(content: Content) -> some View {
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

                    Text(L10n.Sheet.InsufficientBalance.title)
                        .zFont(.semiBold, size: 24, style: Design.Text.primary)
                        .padding(.top, 24)
                        .padding(.bottom, 12)
                    
                    Text(L10n.Sheet.InsufficientBalance.msg)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                        .padding(.bottom, 32)

                    ZashiButton(L10n.General.ok.uppercased()) {
                        isPresented = false
                    }
                    .padding(.bottom, Design.Spacing.sheetBottomSpace)
                }
            }
    }
}

extension View {
    public func insufficientFundsSheet(isPresented: Binding<Bool>) -> some View {
        modifier(
            InsufficientFundsSheetModifier(isPresented: isPresented)
        )
    }
}
