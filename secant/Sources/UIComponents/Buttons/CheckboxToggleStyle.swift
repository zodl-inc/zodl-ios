//
//  CheckboxToggleStyle.swift
//
//
//  Created by Lukáš Korba on 05.10.2023.
//

import SwiftUI

struct CheckboxToggleStyle: ToggleStyle {
    @Environment(\.colorScheme) private var colorScheme
    
    init() { }
    
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            ZStack {
                if configuration.isOn {
                    RoundedRectangle(cornerRadius: Design.Radius._xs)
                        .fill(Design.Checkboxes.onBg.color(colorScheme))
                        .frame(width: 16, height: 16)
                        .overlay {
                            Asset.Assets.check.image
                                .zImage(size: 12, style: Design.Checkboxes.onFg)
                        }
                } else {
                    RoundedRectangle(cornerRadius: Design.Radius._xs)
                        .fill(Design.Checkboxes.offBg.color(colorScheme))
                        .frame(width: 16, height: 16)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._xs)
                                .stroke(Design.Checkboxes.offStroke.color(colorScheme))
                        }
                }
            }
            .onTapGesture {
                configuration.isOn.toggle()
            }

            configuration.label
        }
    }
}

#Preview {
    VStack {
        BoolStateWrapper {
            Toggle("toggle on", isOn: $0)
                .toggleStyle(CheckboxToggleStyle())
        }
        
        BoolStateWrapper(initialValue: false) {
            Toggle("toggle off", isOn: $0)
                .toggleStyle(CheckboxToggleStyle())
        }
    }
    .applyScreenBackground()
    .preferredColorScheme(.dark)
}
