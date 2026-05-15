//
//  EnlargeQRView.swift
//  Zodl
//
//  Created by Lukáš Korba on 2026-03-18.
//

import SwiftUI
import ComposableArchitecture

struct EnlargeQRView<QRContent: View>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.presentationMode) var presentationMode

    @State private var previousBrightness: CGFloat = UIScreen.main.brightness
    @Binding var isPresented: Bool
    var qrContent: QRContent

    func body(content: Content) -> some View {
        ZStack {
            content
                .onAppear {
                    previousBrightness = UIScreen.main.brightness
                    UIScreen.main.brightness = 1.0
                }
                .onChange(of: presentationMode.wrappedValue.isPresented) { isPresented in
                    if !isPresented {
                        UIScreen.main.brightness = previousBrightness
                    }
                }
            
            if isPresented {
                Color.black.opacity(0.9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .zIndex(998)
                    .edgesIgnoringSafeArea(.all)
                    .padding(.horizontal, -4)
                    .onTapGesture {
                        withAnimation {
                            isPresented = false
                        }
                    }
                
                qrContent
                    .zIndex(999)
                    .onTapGesture {
                        withAnimation {
                            isPresented = false
                        }
                    }
            }
        }
    }
}

extension View {
    func enlargeQR(
        isPresented: Binding<Bool>,
        content: @escaping () -> some View
    ) -> some View {
        self.modifier(
            EnlargeQRView(isPresented: isPresented, qrContent: content())
        )
    }
}
