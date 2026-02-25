//
//  Toast.swift
//  Zashi
//
//  Created by Lukáš Korba on 09-18-2024.
//

import SwiftUI
import ComposableArchitecture
import Generated

public struct Toast: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    
    public enum Edge: Equatable {
        case bottom(String)
        case top(String)
        case topDelayed(String)
        case topDelayed5(String)
    }
    
    @Shared(.inMemory(.toast)) public var toast: Edge? = nil

    @State private var message: String? = nil
    @State private var edgeOffset: CGFloat = 20
    @State private var opacity: CGFloat = 0
    @State var top = false
    @State var delay = 1.0

    public func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
                .zIndex(0)
            
            if let message {
                VStack {
                    if !top {
                        Spacer()
                    }
                    
                    if #available(iOS 26.0, *) {
                        Text(message)
                            .zFont(size: 14, style: Design.Btns.Primary.bg)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .glassEffect()
                    } else {
                        Text(message)
                            .zFont(size: 14, style: Design.Btns.Primary.fg)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background {
                                RoundedRectangle(cornerRadius: Design.Radius._xl)
                                    .fill(Design.Btns.Primary.bg.color(colorScheme))
                            }
                    }
                    
                    if top {
                        Spacer()
                    }
                }
                .opacity(opacity)
                .screenHorizontalPadding()
                .padding(.top, top ? edgeOffset : 0)
                .padding(.bottom, top ? 0 : edgeOffset)
                .zIndex(1)
                .onAppear {
                    withAnimation(.easeIn(duration: 0.25)) {
                        edgeOffset = 50
                        opacity = 1
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (delay + 0.25)) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            edgeOffset = 20
                            opacity = 0
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (delay + 0.5)) {
                        $toast.withLock { $0 = nil }
                        self.message = nil
                    }
                }
            }
        }
        .onChange(of: toast) { value in
            guard message == nil else { return }
            
            switch value {
            case .bottom(let msg):
                message = msg
                top = false
                delay = 1.0
            case .top(let msg):
                message = msg
                top = true
                delay = 1.0
            case .topDelayed(let msg):
                message = msg
                top = true
                delay = 3.0
            case .topDelayed5(let msg):
                message = msg
                top = true
                delay = 5.0
            case .none: break
            }
        }
    }
}

extension View {
    public func toast() -> some View {
        modifier(
            Toast()
        )
    }
}
