//
//  ZashiSelectionCard.swift
//  Zodl
//

import SwiftUI

struct ZashiSelectionCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    init(
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                radioIndicator
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .zFont(.medium, size: 16, style: Design.Text.primary)

                    Text(subtitle)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(20)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._2xl)
                    .fill(
                        isSelected
                            ? Design.Surfaces.bgPrimary.color(colorScheme)
                            : Design.Surfaces.bgSecondary.color(colorScheme)
                    )
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                                .strokeBorder(Design.Checkboxes.onBg.color(colorScheme), lineWidth: 2)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var radioIndicator: some View {
        ZStack {
            Circle()
                .fill(
                    isSelected
                        ? Design.Checkboxes.onBg.color(colorScheme)
                        : Design.Checkboxes.offBg.color(colorScheme)
                )
                .overlay {
                    if !isSelected {
                        Circle()
                            .stroke(Design.Checkboxes.offStroke.color(colorScheme))
                    }
                }

            if isSelected {
                Circle()
                    .fill(Design.Checkboxes.onFg.color(colorScheme))
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
