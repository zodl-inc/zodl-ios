//
//  View+InnerShadow.swift
//  Zashi
//
//  Created by Francisco Gindre on 10/22/21.
//

import SwiftUI

extension View {
    /**
    drops an inner shadow with the given shape in the receiving view.
    Credits: https://www.hackingwithswift.com/plus/swiftui-special-effects/shadows-and-glows
    */
    func innerShadow<S: Shape>(
        using shape: S,
        angle: Angle = .degrees(0),
        color: Color = .black,
        width: CGFloat = 6,
        blur: CGFloat = 6
    ) -> some View {
        let finalX = CGFloat(cos(angle.radians - .pi / 2))
        let finalY = CGFloat(sin(angle.radians - .pi / 2))
        return self
            .overlay(
                shape
                    .stroke(color, lineWidth: width)
                    .offset(x: finalX * width * 0.6, y: finalY * width * 0.6)
                    .blur(radius: blur)
                    .mask(shape)
            )
    }
}
