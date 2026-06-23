//
//  ZashiBack.swift
//
//
//  Created by Lukáš Korba on 04.10.2023.
//

import SwiftUI

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
                    ToolbarItem(placement: .zashiLeading) {
                        Button {
                            if let customDismiss {
                                customDismiss()
                            } else {
                                dismiss()
                            }
                        } label: {
#if os(macOS)
                            backIcon()
                                .padding(.horizontal, 6)
#else
                            if #available(iOS 26.0, *) {
                                backIcon()
                            } else {
                                backIcon()
                                    .padding(.trailing, 24)
                                    .padding(8)
                            }
#endif
                        }
                        .disabled(disabled)
                        .accessibilityIdentifier(AccessibilityID.Navigation.back)
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
    func zashiBack(
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

    /// Back/dismiss control for a screen that is the ROOT of a sidebar SECTION's navigation stack.
    /// On iOS the section is presented (popover/push), so this is the normal `.zashiBack` and the back
    /// arrow dismisses it. On macOS the section is a peer-root inside the split — there is nothing to go
    /// back to — so it renders NOTHING (no back button). RULE: use this instead of `.zashiBack` on every
    /// sidebar-section root screen, so adding a new section can never reintroduce the macOS back-button bug.
    @ViewBuilder func zashiSectionRootBack(customDismiss: @escaping () -> Void) -> some View {
#if os(macOS)
        self
#else
        zashiBack(customDismiss: customDismiss)
#endif
    }
}
