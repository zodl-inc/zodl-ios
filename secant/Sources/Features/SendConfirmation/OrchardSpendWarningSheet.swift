//
//  OrchardSpendWarningSheet.swift
//  Zashi
//
//  Created by Claude Fable 5 on 31-07-2026.
//

import SwiftUI

struct OrchardSpendWarningSheetModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    @Binding var isPresented: Bool
    let onContinue: () -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .zashiSheet(isPresented: $isPresented, onDismiss: onDismiss) {
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

                    Text(localizable: .sheetOrchardSpendTitle)
                        .zFont(.semiBold, size: 24, style: Design.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                        .padding(.bottom, 12)

                    Text(localizable: .sheetOrchardSpendMsg)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                        .padding(.bottom, 32)

                    ZashiButton(
                        String(localizable: .sheetOrchardSpendContinue),
                        type: .destructive1
                    ) {
                        onContinue()
                    }
                    .padding(.bottom, 12)

                    ZashiButton(String(localizable: .generalCancel)) {
                        onCancel()
                    }
                    .padding(.bottom, Design.Spacing.sheetBottomSpace)
                }
            }
    }
}

extension View {
    func orchardSpendWarningSheet(
        isPresented: Binding<Bool>,
        onContinue: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(
            OrchardSpendWarningSheetModifier(
                isPresented: isPresented,
                onContinue: onContinue,
                onCancel: onCancel,
                onDismiss: onDismiss
            )
        )
    }
}
