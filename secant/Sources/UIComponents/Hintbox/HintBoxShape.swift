//
//  HintBoxShape.swift
//  
//
//  Created by Lukáš Korba on 23.11.2023.
//

import SwiftUI

struct HintBoxShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: rect.width, y: 0))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height))

            path.closeSubpath()
        }
    }
}

struct HintBoxShapeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background {
                HintBoxShape()
                    .foregroundColor(Asset.Colors.secondary.color)
                    .shadow(radius: 5, y: 6)
            }
            .overlay {
                HintBoxShape()
                    .stroke()
            }
    }
}

extension View {
    func hintBoxShape() -> some View {
        modifier(
            HintBoxShapeModifier()
        )
    }
}

#Preview {
    VStack {
        Text("Hi, this is a test of the hintBox shape with the shadow")
            .hintBoxShape()
    }
    .padding(40)
    .background(.green)
}
