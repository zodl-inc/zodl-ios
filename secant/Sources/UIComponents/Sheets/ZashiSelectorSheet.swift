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
        // macOS: publish to the single root card host (`.macCardHost()`) — the definite-size selector card
        // (the list needs a real height) rendered centered + dimmed over the WHOLE window, above the 536pt
        // content cap (MODALS.md Rule #5). The selector draws its own close button, so the host omits one.
        content
            .macCardPublish(
                isPresented: isPresented,
                fixedWidth: 460,
                fixedHeightRange: 320...600,
                horizontalPadding: 0,
                showsCloseButton: false,
                dismiss: { isPresented = false }
            ) {
                selectorContent
            }
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
