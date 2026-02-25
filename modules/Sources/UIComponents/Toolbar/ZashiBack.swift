//
//  ZashiBack.swift
//
//
//  Created by Lukáš Korba on 04.10.2023.
//

import SwiftUI
import Generated

struct ZashiBackModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    let disabled: Bool
    let hidden: Bool
    let invertedColors: Bool
    let customDismiss: (() -> Void)?
    
    func body(content: Content) -> some View {
        if hidden {
            content
                .navigationBarBackButtonHidden(true)
        } else {
            content
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            if let customDismiss {
                                customDismiss()
                            } else {
                                dismiss()
                            }
                        } label: {
                            if #available(iOS 26.0, *) {
                                backIcon()
                            } else {
                                backIcon()
                                    .padding(.trailing, 24)
                                    .padding(8)
                            }
                        }
                        .disabled(disabled)
                    }
                }
        }
    }
    
    @ViewBuilder private func backIcon() -> some View {
        HStack {
            Asset.Assets.Icons.arrowNarrowLeft.image
                .zImage(size: 24,
                        color: invertedColors ? Asset.Colors.secondary.color : Asset.Colors.primary.color
                )
        }
    }
}

extension View {
    public func zashiBack(
        _ disabled: Bool = false,
        hidden: Bool = false,
        invertedColors: Bool = false,
        customDismiss: (() -> Void)? = nil
    ) -> some View {
        modifier(
            ZashiBackModifier(
                disabled: disabled,
                hidden: hidden,
                invertedColors: invertedColors,
                customDismiss: customDismiss
            )
        )
    }
}
