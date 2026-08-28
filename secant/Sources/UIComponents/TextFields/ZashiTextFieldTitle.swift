//
//  ZashiTextFieldTitle.swift
//  Zashi
//
//  Created by Michal Fousek on 24.08.2026.
//

import SwiftUI

/// The canonical title above a `ZashiTextField`-style input, with an optional trailing
/// accessory (e.g. the Max chip) separated by a `Spacer`.
///
/// `ZashiTextField` renders its own `title:` through this view, so the styling below is
/// the single source of truth for field titles. Screens that need something next to the
/// title — and therefore cannot use the field's built-in `title:` — place this component
/// directly above a `title: nil` field, inside a `VStack(spacing: 0)`, with
/// `.padding(.bottom, 6)` on this row: that reproduces the field's own 6pt title gap.
struct ZashiTextFieldTitle<AccessoryContent: View>: View {
    let title: String

    @ViewBuilder let accessoryView: AccessoryContent

    init(
        _ title: String,
        @ViewBuilder accessoryView: () -> AccessoryContent
    ) {
        self.title = title
        self.accessoryView = accessoryView()
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.custom(FontFamily.Inter.medium.name, size: 14))
                .zForegroundColor(Design.Inputs.Filled.label)

            if !(accessoryView is EmptyView) {
                Spacer()

                accessoryView
            }
        }
    }
}

extension ZashiTextFieldTitle where AccessoryContent == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        ZashiTextFieldTitle("Amount")

        ZashiTextFieldTitle("Amount") {
            Text("Accessory")
        }
    }
    .padding()
}
