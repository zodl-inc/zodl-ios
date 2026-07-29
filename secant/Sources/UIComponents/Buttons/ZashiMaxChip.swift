//
//  ZashiMaxChip.swift
//  Zashi
//
//  Created by Michal Fousek on 29.07.2026.
//

import SwiftUI

/// A small pill-shaped chip that lets the user prefill the maximum spendable amount.
/// Shared by the Send, Pay and Swap amount rows. The chip never displays an amount
/// itself — it is label-only; the caller always supplies the localized title.
///
/// The two Figma presentations each pair a corner radius WITH a letter casing, so the
/// pairing is owned by `Style` rather than by the caller — a call site picks a
/// presentation, never a radius and a casing independently:
/// - `.standard` (Send, Pay): `Design.Radius._xl`, title as given (e.g. "Max").
/// - `.swap` (Swap): `Design.Radius._md`, title uppercased (e.g. "MAX").
///
/// When `isInFlight` is `true`, the label is replaced by a spinner (matching the
/// `Spendable` label's spinner in `SwapForm`) and the chip is not tappable. When
/// `isEnabled` is `false`, the chip dims using the same `Design.Text.disabled` token the
/// rest of the design system uses for disabled labels, rather than an ad-hoc opacity.
struct ZashiMaxChip: View {
    /// Visual presentation of the chip. Each case fixes both the corner radius and the
    /// letter casing of the title, so the two can never drift apart from the design.
    enum Style: Equatable {
        /// Send and Pay screens: 12pt radius, title rendered as given ("Max").
        case standard
        /// Swap screen: 8pt radius, title rendered uppercased ("MAX").
        case swap

        var cornerRadius: CGFloat {
            switch self {
            case .standard: Design.Radius._xl
            case .swap: Design.Radius._md
            }
        }

        func styledTitle(_ title: String) -> String {
            switch self {
            case .standard: title
            case .swap: title.uppercased()
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let style: Style
    let isEnabled: Bool
    let isInFlight: Bool
    let action: () -> Void

    init(
        title: String,
        style: Style = .standard,
        isEnabled: Bool = true,
        isInFlight: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.isEnabled = isEnabled
        self.isInFlight = isInFlight
        self.action = action
    }

    var body: some View {
        let styledTitle = style.styledTitle(title)

        Button {
            action()
        } label: {
            Group {
                if isInFlight {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 11, height: 14)
                } else {
                    Text(styledTitle)
                        .zFont(
                            .semiBold,
                            size: 14,
                            style: isEnabled ? Design.Text.secondary : Design.Text.disabled
                        )
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background {
                RoundedRectangle(cornerRadius: style.cornerRadius)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
            }
        }
        .disabled(!isEnabled || isInFlight)
        .accessibilityLabel(styledTitle)
    }
}

#Preview {
    VStack(spacing: 15) {
        ZashiMaxChip(title: String(localizable: .generalMax)) {}

        ZashiMaxChip(title: String(localizable: .generalMax), style: .swap) {}

        ZashiMaxChip(title: String(localizable: .generalMax), isEnabled: false) {}

        ZashiMaxChip(title: String(localizable: .generalMax), isInFlight: true) {}
    }
    .screenHorizontalPadding()
}
