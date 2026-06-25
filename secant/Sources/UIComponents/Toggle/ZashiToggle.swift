//
//  ZashiToggle.swift
//
//
//  Created by Lukáš Korba on 04-16-2024.
//

import SwiftUI

struct ZashiToggle: View {
    @Binding var isOn: Bool
    let label: String
    let textColor: Color
    let textSize: CGFloat
    
    init(
        isOn: Binding<Bool>,
        label: String = "",
        textColor: Color = Asset.Colors.primary.color,
        textSize: CGFloat = 14
    ) {
        self._isOn = isOn
        self.label = label
        self.textColor = textColor
        self.textSize = textSize
    }
    
    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 0) {
                Toggle(isOn: $isOn, label: {})
                    .toggleStyle(CheckboxToggleStyle())
                    .padding(.trailing, 8)
                
                Text(label)
                    .zFont(.medium, size: textSize, style: Design.Text.primary)
                    .multilineTextAlignment(.leading)
            }
        }
        .foregroundColor(textColor)
#if os(macOS)
        // macOS: force the plain (full-area) button style explicitly. When a ZashiToggle is nested inside
        // another Button's label (e.g. the Keystone account row), the inner button doesn't inherit the
        // app-wide plain style, so macOS draws its default rounded bezel behind the toggle. Standalone
        // usages already get the plain style, so this is a no-op there. iOS is unaffected.
        .zashiPlainButtonStyle()
#endif
    }
}

#Preview {
    BoolStateWrapper(initialValue: false) {
        ZashiToggle(isOn: $0, label: "I acknowledge")
    }
}
