//
//  MessageShape.swift
//
//
//  Created by Lukáš Korba on 25.10.2023.
//

import SwiftUI

struct MessageShape: Shape {
    enum Orientation: Sendable {
        case left
        case right
    }
    
    let orientation: MessageShape.Orientation
    
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: rect.height))

            if orientation == .left {
                path.addLine(to: CGPoint(x: 15, y: rect.height))
                path.addLine(to: CGPoint(x: 15, y: rect.height + 7))
                path.addLine(to: CGPoint(x: 35, y: rect.height))
            } else {
                path.addLine(to: CGPoint(x: rect.width - 35, y: rect.height))
                path.addLine(to: CGPoint(x: rect.width - 15, y: rect.height + 7))
                path.addLine(to: CGPoint(x: rect.width - 15, y: rect.height))
            }

            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width, y: 0))
            path.closeSubpath()
        }
    }
}

struct MessageShapeModifier: ViewModifier {
    let filled: Color?
    let border: Color?
    let orientation: MessageShape.Orientation
    
    func body(content: Content) -> some View {
        content
            .background {
                if let filled {
                    MessageShape(orientation: orientation)
                        .foregroundColor(filled)
                }
            }
            .overlay {
                MessageShape(orientation: orientation)
                    .stroke(border ?? .clear)
            }
    }
}

extension View {
    func messageShape(
        filled: Color? = nil,
        border: Color? = Asset.Colors.primary.color,
        orientation: MessageShape.Orientation = .left
    ) -> some View {
        modifier(
            MessageShapeModifier(
                filled: filled,
                border: border,
                orientation: orientation
            )
        )
    }
}

#Preview {
    VStack {
        Text("some message")
            .padding(5)
            .messageShape(
                filled: Asset.Colors.messageBcgReceived.color,
                orientation: .right
            )
            .padding(.bottom, 20)

        Text("some message")
            .padding(5)
            .messageShape()
            .padding(.bottom, 20)
        
        Text("some message")
            .frame(width: 320, height: 145)
            .messageShape(filled: Asset.Colors.shade72.color)
    }
}
