//
//  ZashiTextField.swift
//
//
//  Created by Lukáš Korba on 22.05.2024.
//

import SwiftUI

struct ZashiTextField<PrefixContent, InputReplacementContent, AccessoryContent>: View where PrefixContent: View, InputReplacementContent: View, AccessoryContent: View {
    @Environment(\.colorScheme) private var colorScheme

    let addressFont: Bool
    var text: Binding<String>
    var placeholder: String
    var title: String?
    var error: String?
    let eraseAction: (() -> Void)?
    // Inner-TextField accessibility id (e2e affordance). Applied to
    // the inner SwiftUI TextField directly so a maestro tap-by-id
    // lands on the input's hit-test region, AND so the wrapper's
    // accessory views (icon buttons) keep their own accessibility
    // identifiers — without this, an outer `.accessibilityIdentifier(...)`
    // modifier on ZashiTextField merges all inner elements into one
    // accessibility node and the icon buttons stop being findable
    // by their own ids.
    var inputAccessibilityIdentifier: String?

    @ViewBuilder let accessoryView: AccessoryContent?
    @ViewBuilder let inputReplacementView: InputReplacementContent?
    @ViewBuilder let prefixView: PrefixContent?

    init(
        addressFont: Bool = false,
        text: Binding<String>,
        placeholder: String = "",
        title: String? = nil,
        error: String? = nil,
        eraseAction: (() -> Void)? = nil,
        inputAccessibilityIdentifier: String? = nil,
        accessoryView: AccessoryContent? = EmptyView(),
        inputReplacementView: InputReplacementContent? = EmptyView(),
        prefixView: PrefixContent? = EmptyView()
    ) {
        self.addressFont = addressFont
        self.text = text
        self.placeholder = placeholder
        self.title = title
        self.error = error
        self.eraseAction = eraseAction
        self.inputAccessibilityIdentifier = inputAccessibilityIdentifier
        self.accessoryView = accessoryView
        self.inputReplacementView = inputReplacementView
        self.prefixView = prefixView
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.custom(FontFamily.Inter.medium.name, size: 14))
                    .zForegroundColor(Design.Inputs.Filled.label)
                    .padding(.bottom, title.isEmpty ? 0 : 6)
            }
            
            HStack(spacing: 0) {
                if let prefixView {
                    prefixView
                        .padding(.trailing, 8)
                }

                if let inputReplacementView, !(inputReplacementView is EmptyView) {
                    inputReplacementView
                } else {
                    let field = TextField(
                        "",
                        text: text,
                        prompt:
                            Text(placeholder)
                                .font(.custom(FontFamily.Inter.regular.name, size: 16))
                                .foregroundColor(Design.Inputs.Default.text.color(colorScheme))
                    )
#if os(iOS)
                    .autocapitalization(.none)
#endif
                    .autocorrectionDisabled()
                    .font(.custom(
                        addressFont
                        ? FontFamily.RobotoMono.regular.name
                        : FontFamily.Inter.regular.name,
                        size: 14)
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accentColor(Asset.Colors.primary.color)
                    if let inputAccessibilityIdentifier {
                        field.accessibilityIdentifier(inputAccessibilityIdentifier)
                    } else {
                        field
                    }
                }
                
                Spacer()
                
                if let accessoryView {
                    if let eraseAction {
                        Button {
                            eraseAction()
                        } label: {
                            accessoryView
                                .padding(.leading, 8)
                        }
                    } else {
                        accessoryView
                            .padding(.leading, 8)
                    }
                }
            }
            .padding(.vertical, (inputReplacementView is EmptyView || inputReplacementView == nil) ? 12 : 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: Design.Radius._lg)
                    .fill(Design.Inputs.Default.bg.color(colorScheme))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius._lg)
                            .stroke(
                                error == nil
                                ? Design.Inputs.Default.bg.color(colorScheme)
                                : Design.Inputs.ErrorFilled.stroke.color(colorScheme)
                            )
                    }
            )

            if let error {
                Text(error)
                    .zForegroundColor(Design.Inputs.ErrorFilled.hint)
                    .font(.custom(FontFamily.Inter.regular.name, size: 14))
                    .padding(.top, 6)
            }
        }
    }
}

#Preview {
    VStack(spacing: 30) {
        StringStateWrapper {
            ZashiTextField(
                text: $0,
                placeholder: "Placeholder"
            )
            
            ZashiTextField(
                text: $0,
                placeholder: "ZEC",
                title: "Amount",
                prefixView:
                    ZcashSymbol()
                    .frame(width: 12, height: 20)
                    .zForegroundColor(Design.Inputs.Default.text)
            )
            
            ZashiTextField(
                text: $0,
                placeholder: "Placeholder",
                title: "Title",
                accessoryView:
                    Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Inputs.Default.text),
                prefixView:
                    Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Inputs.Default.text)
            )
            
            ZashiTextField(
                text: $0,
                placeholder: "Placeholder",
                title: "Title",
                error: "This contact name exceeds the 32-character limit. Please shorten the name.",
                accessoryView:
                    Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Inputs.Default.text),
                prefixView:
                    Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Inputs.Default.text)
            )
        }
    }
    .padding()
}
