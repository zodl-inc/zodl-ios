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
    let checkboxSpacing: CGFloat
    let checkboxTopPadding: CGFloat
    let textTracking: CGFloat
    let textLineSpacing: CGFloat
    let textVerticalPadding: CGFloat
    let expandsTextVertically: Bool
    
    init(
        isOn: Binding<Bool>,
        label: String = "",
        textColor: Color = Asset.Colors.primary.color,
        textSize: CGFloat = 14,
        checkboxSpacing: CGFloat = 8,
        checkboxTopPadding: CGFloat = 0,
        textTracking: CGFloat = 0,
        textLineSpacing: CGFloat = 0,
        textVerticalPadding: CGFloat = 0,
        expandsTextVertically: Bool = false
    ) {
        self._isOn = isOn
        self.label = label
        self.textColor = textColor
        self.textSize = textSize
        self.checkboxSpacing = checkboxSpacing
        self.checkboxTopPadding = checkboxTopPadding
        self.textTracking = textTracking
        self.textLineSpacing = textLineSpacing
        self.textVerticalPadding = textVerticalPadding
        self.expandsTextVertically = expandsTextVertically
    }
    
    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 0) {
                Toggle(isOn: $isOn, label: {})
                    .toggleStyle(CheckboxToggleStyle())
                    .padding(.top, checkboxTopPadding)
                    .padding(.trailing, checkboxSpacing)
                
                labelText
            }
        }
        .foregroundColor(textColor)
    }

    @ViewBuilder private var labelText: some View {
        let text = Text(label)
            .zFont(.medium, size: textSize, style: Design.Text.primary)
            .tracking(textTracking)
            .lineSpacing(textLineSpacing)
            .padding(.vertical, textVerticalPadding)
            .multilineTextAlignment(.leading)
        if expandsTextVertically {
            text.fixedSize(horizontal: false, vertical: true)
        } else {
            text
        }
    }
}

#Preview {
    BoolStateWrapper(initialValue: false) {
        ZashiToggle(isOn: $0, label: "I acknowledge")
    }
}
