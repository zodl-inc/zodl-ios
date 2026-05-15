//
//  DescriptiveToggle.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-11-11.
//

import SwiftUI

struct DescriptiveToggle: View {
    @Environment(\.colorScheme) var colorScheme
    
    @Binding var isOn: Bool
    let title: String
    let desc: String
    
    init(
        isOn: Binding<Bool>,
        title: String,
        desc: String
    ) {
        self._isOn = isOn
        self.title = title
        self.desc = desc
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)

                Text(desc)
                    .zFont(size: 12, style: Design.Text.tertiary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity)
            .padding(.trailing, Design.Spacing._2xl)

            Toggle("", isOn: _isOn)
                .labelsHidden()
        }
        .padding(Design.Spacing._2xl)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
        }
        .overlay {
            if isOn {
                RoundedRectangle(cornerRadius: Design.Radius._xl)
                    .inset(by: 1.5)
                    .stroke(Design.Utility.Gray._950.color(colorScheme), lineWidth: 1)
            }
        }
    }
}

#Preview {
    BoolStateWrapper(initialValue: false) {
        DescriptiveToggle(isOn: $0, title: "title", desc: "desc")
    }
}
