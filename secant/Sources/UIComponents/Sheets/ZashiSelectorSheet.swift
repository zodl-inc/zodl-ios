//
//  ZashiSelectorSheet.swift
//  Zashi
//
//  Created by Lukáš Korba on 2026-06-22.
//

import SwiftUI

/// Presents a searchable selector (swap token / address-book chain) whose body is a scrollable list.
///
/// On iOS this is the existing anchored `.popover`. On macOS a popover sizes itself to the content's
/// *intrinsic* height — and a `List` / `ScrollView` has none — so it collapses to an unusable bubble.
/// There we present the same centered, dimmed card the rest of the app uses for sheets (see
/// `ZashiSheet`), at a definite size so the inner list can actually fill it and scroll.
///
/// The `content` supplies its own header + close button; this modifier only adds the backdrop, ESC,
/// and click-outside-to-dismiss affordances (all of which just flip `isPresented`, matching the
/// reducers' close actions).
struct ZashiSelectorSheetModifier<SelectorContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    var selectorContent: SelectorContent

    func body(content: Content) -> some View {
#if os(macOS)
        content
            .overlay {
                if isPresented {
                    GeometryReader { geo in
                        ZStack {
                            // Dimmed backdrop — click anywhere outside the card to dismiss.
                            Rectangle()
                                .fill(Color.black.opacity(0.45))
                                .ignoresSafeArea()
                                .onTapGesture { isPresented = false }

                            // Card: phone-width, definite height so the list fills and scrolls.
                            selectorContent
                                .frame(width: 460, height: max(320, min(600, geo.size.height - 80)))
                                .background(Asset.Colors.background.color)
                                .clipShape(RoundedRectangle(cornerRadius: Design.Radius._4xl))
                                .shadow(color: Color.black.opacity(0.25), radius: 24, x: 0, y: 10)
                                .background {
                                    // ESC dismisses, matching the standard card behaviour.
                                    Button("") { isPresented = false }
                                        .keyboardShortcut(.cancelAction)
                                        .opacity(0)
                                }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: isPresented)
#else
        content
            .popover(isPresented: $isPresented) {
                selectorContent
                    .padding(.horizontal, 4)
                    .applyScreenBackground()
            }
#endif
    }
}

extension View {
    func zashiSelectorSheet(
        isPresented: Binding<Bool>,
        @ViewBuilder content: () -> some View
    ) -> some View {
        modifier(ZashiSelectorSheetModifier(isPresented: isPresented, selectorContent: content()))
    }
}
