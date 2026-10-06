//
//  LedgerAdvancedOptionsCard.swift
//  Zashi
//
//  MOB-2020: Figma's "Advanced options" card (collapsed 1728:3543, expanded 1728:3636, error
//  1728:3763), under the device list on step 2 -- where the user picks which ZIP 32 account of
//  the Ledger to pair (Android `LedgerAdvancedOptions.kt`). Collapsed by default; the header
//  toggles it, and the picker's own `advancedOptionsToggleTapped` refuses to collapse it while
//  the account index field is invalid, so the reason Connect is disabled stays in view.
//
//  `ZashiTextField`'s `error:` draws its own red helper line below the field, but has no way to
//  show a non-error one -- Figma's valid state keeps the same helper text, just not red -- so
//  this composes `ZashiTextField` (label, field, border colour and the red helper) with a second,
//  plain helper `Text` of its own, shown only while valid, rather than forking the field.
//

import SwiftUI

struct LedgerAdvancedOptionsCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let isExpanded: Bool
    @Binding var accountIndexText: String
    let isAccountIndexValid: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 0) {
                    Text(localizable: .ledgerDevicePickerAdvancedOptions)
                        .zFont(.semiBold, size: 14, style: Design.Text.primary)

                    Spacer()

                    (isExpanded ? Asset.Assets.chevronUp : Asset.Assets.chevronDown).image
                        .zImage(size: 20, style: Design.Text.primary)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .contentShape(Rectangle())
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Text(localizable: .ledgerDevicePickerAdvancedOptionsDesc)
                        .zFont(size: 12, style: Design.Text.tertiary)

                    ZashiTextField(
                        text: $accountIndexText,
                        title: String(localizable: .ledgerDevicePickerAccountIndex),
                        error: isAccountIndexValid ? nil : String(localizable: .ledgerDevicePickerAccountIndexHint)
                    )
                    .keyboardType(.numberPad)
                    .padding(.top, 16)

                    if isAccountIndexValid {
                        Text(localizable: .ledgerDevicePickerAccountIndexHint)
                            .zFont(size: 14, style: Design.Inputs.Default.hint)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .stroke(Design.Surfaces.strokeSecondary.color(colorScheme), lineWidth: 1)
                }
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        LedgerAdvancedOptionsCard(
            isExpanded: false,
            accountIndexText: .constant("0"),
            isAccountIndexValid: true,
            onToggle: { }
        )

        LedgerAdvancedOptionsCard(
            isExpanded: true,
            accountIndexText: .constant("3"),
            isAccountIndexValid: true,
            onToggle: { }
        )

        LedgerAdvancedOptionsCard(
            isExpanded: true,
            accountIndexText: .constant("150"),
            isAccountIndexValid: false,
            onToggle: { }
        )
    }
    .padding()
}
