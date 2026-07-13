//
//  ZashiBack.swift
//
//
//  Created by Lukáš Korba on 04.10.2023.
//

import SwiftUI

struct ZashiBackV2Modifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let disabled: Bool
    let hidden: Bool
    let invertedColors: Bool
    let background: Bool
    let customDismiss: (() -> Void)?
    
    func body(content: Content) -> some View {
        if hidden {
            content
                .navigationBarBackButtonHidden(true)
        } else {
            content
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    ToolbarItem(placement: .zashiLeading) {
                        Button {
                            if let customDismiss {
                                customDismiss()
                            } else {
                                dismiss()
                            }
                        } label: {
#if os(macOS)
                            // macOS: widen the close icon so its Liquid Glass capsule matches `.zashiBack`'s
                            // width — a bare 24pt icon makes macOS 26 size the capsule to that narrow width
                            // (a tall pill). Same `.horizontal, 6` as `.zashiBack`'s macOS branch.
                            Group {
                                if invertedColors {
                                    Asset.Assets.buttonCloseX.image
                                        .zImage(size: 24, color: Asset.Colors.ZDesign.shark100.color)
                                } else {
                                    Asset.Assets.buttonCloseX.image
                                        .zImage(size: 24, style: Design.Btns.Tertiary.fg)
                                }
                            }
                            .zashiToolbarIconPadding()
#else
                            if #available(iOS 26.0, *) {
                                if invertedColors {
                                    Asset.Assets.buttonCloseX.image
                                        .zImage(size: 24, color: Asset.Colors.ZDesign.shark100.color)
                                } else {
                                    Asset.Assets.buttonCloseX.image
                                        .zImage(size: 24, style: Design.Btns.Tertiary.fg)
                                }
                            } else {
                                if invertedColors {
                                    Asset.Assets.buttonCloseX.image
                                        .zImage(size: 24, color: Asset.Colors.ZDesign.shark100.color)
                                        .padding(8)
                                        .background {
                                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                                .fill(Asset.Colors.ZDesign.shark900.color)
                                        }
                                } else {
                                    Asset.Assets.buttonCloseX.image
                                        .zImage(size: 24, style: Design.Btns.Tertiary.fg)
                                        .padding(8)
                                        .background {
                                            if background {
                                                RoundedRectangle(cornerRadius: Design.Radius._xl)
                                                    .fill(Design.Btns.Tertiary.bg.color(colorScheme))
                                            }
                                        }
                                }
                            }
#endif
                        }
                        .disabled(disabled)
                    }
                }
        }
    }
}

extension View {
    func zashiBackV2(
        _ disabled: Bool = false,
        hidden: Bool = false,
        invertedColors: Bool = false,
        background: Bool = true,
        customDismiss: (() -> Void)? = nil
    ) -> some View {
        modifier(
            ZashiBackV2Modifier(
                disabled: disabled,
                hidden: hidden,
                invertedColors: invertedColors,
                background: background,
                customDismiss: customDismiss
            )
        )
    }
}
