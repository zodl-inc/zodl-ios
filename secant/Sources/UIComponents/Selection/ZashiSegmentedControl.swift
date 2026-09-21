//
//  ZashiSegmentedControl.swift
//  Zodl
//

import SwiftUI

struct ZashiSegmentedControl<Selection: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme

    let options: [Selection]
    let selection: Selection
    let title: (Selection) -> String
    let onSelect: (Selection) -> Void

    init(
        options: [Selection],
        selection: Selection,
        title: @escaping (Selection) -> String,
        onSelect: @escaping (Selection) -> Void
    ) {
        self.options = options
        self.selection = selection
        self.title = title
        self.onSelect = onSelect
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            optionStack(axis: .horizontal)
            optionStack(axis: .vertical)
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    private func optionStack(axis: Axis) -> some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 4))
            : AnyLayout(VStackLayout(spacing: 4))

        return layout {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection

                Button {
                    onSelect(option)
                } label: {
                    Text(title(option))
                        .zFont(
                            .medium,
                            size: 16,
                            color: isSelected
                                ? selectedForeground
                                : Design.Text.primary.color(colorScheme)
                        )
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Design.Radius._lg)
                                    .fill(selectedBackground)
                            }
                        }
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private var selectedBackground: Color {
        colorScheme == .light
            ? Design.Surfaces.bgPrimary.color(colorScheme)
            : Design.Btns.Primary.bg.color(colorScheme)
    }

    private var selectedForeground: Color {
        colorScheme == .light
            ? Design.Text.primary.color(colorScheme)
            : Design.Btns.Primary.fg.color(colorScheme)
    }
}
