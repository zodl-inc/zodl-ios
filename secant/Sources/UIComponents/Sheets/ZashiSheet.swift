//
//  ZashiSheet.swift
//  modules
//
//  Created by Lukáš Korba on 31.03.2025.
//

import Perception
import SwiftUI
import ComposableArchitecture

private struct SheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func readHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: SheetHeightKey.self,
                                value: proxy.size.height)
            }
        )
        .onPreferenceChange(SheetHeightKey.self, perform: onChange)
    }
}

extension View {
    @ViewBuilder
    func heightChangePreference(_ completion: @escaping (CGFloat) -> Void) -> some View {
        self
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: ContentHeightKey.self, value: geometry.size.height)
                        .onPreferenceChange(ContentHeightKey.self) { height in
                            completion(height)
                        }
                }
            }
    }
}

struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ZashiSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let horizontalPadding: CGFloat
    let dragIndicatorVisibility: Visibility
    let onDismiss: (() -> Void)?
    @State var sheetHeight: CGFloat = .zero
    let sheetContent: () -> SheetContent

    func body(content: Content) -> some View {
#if os(macOS)
        // macOS: publish to the single root card host (`.macCardHost()`), which renders the centered,
        // dimmed, content-hugging card OVER THE WHOLE WINDOW — escaping the content cap
        // (`Design.Mac.viewCapWidth`, MODALS.md Rule #5). Replaces the old local `.overlay`, whose dimmed
        // backdrop was clamped to the capped
        // content column.
        content
            .macCardPublish(
                isPresented: isPresented,
                horizontalPadding: horizontalPadding,
                showsCloseButton: true,
                dismiss: { isPresented = false }
            ) {
                sheetContent()
            }
            .onChange(of: isPresented) { _, newValue in
                if !newValue { onDismiss?() }
            }
#else
        content
            .sheet(isPresented: $isPresented, onDismiss: onDismiss) {
                // A `.sheet` closure renders in a NEW view tree: without its own tracking scope,
                // `@ObservableState` reads inside never register and the sheet body does not
                // re-render on store changes (the runtime Perception warning field-caught
                // 2026-08-03 on the migration status screen). The content closure is also stored
                // UNEVALUATED (`() -> SheetContent`) so its store reads happen here, inside the
                // scope — never eagerly at the call site.
                WithPerceptionTracking {
                    if #available(iOS 26.0, *) {
                        mainBody26()
                            .presentationDetents([.height(sheetHeight)])
                            .presentationDragIndicator(dragIndicatorVisibility)
                            .padding(.horizontal, horizontalPadding)
                            .applySheetBackground()
                    } else if #available(iOS 16.4, *) {
                        mainBody()
                            .id(sheetHeight)
                            .presentationDetents([.height(sheetHeight)])
                            .presentationDragIndicator(dragIndicatorVisibility)
                            .presentationCornerRadius(Design.Radius._4xl)
                            .padding(.horizontal, horizontalPadding)
                            .applySheetBackground()
                    } else if #available(iOS 16.0, *) {
                        mainBody()
                            .id(sheetHeight)
                            .presentationDetents([.height(sheetHeight)])
                            .presentationDragIndicator(dragIndicatorVisibility)
                            .padding(.horizontal, horizontalPadding)
                            .applySheetBackground()
                    } else {
                        mainBody(stickToBottom: true)
                            .padding(.horizontal, horizontalPadding)
                            .applySheetBackground()
                    }
                }
            }
#endif
    }

    @ViewBuilder func mainBody(stickToBottom: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if stickToBottom {
               Spacer()
            }

            sheetContent()
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .task {
                        sheetHeight = proxy.size.height
                    }
            }
        }
    }

    @ViewBuilder func mainBody26(stickToBottom: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if stickToBottom {
                Spacer()
            }

            sheetContent()
        }
        .readHeight { height in
            if abs(height - sheetHeight) > 1 {
                sheetHeight = height
            }
        }
    }
}

#if os(macOS)
extension View {
    /// RULE #5: the macOS sheet card surface is Liquid Glass (macOS 26+), with a solid fallback below.
    /// macOS-only — the iOS sheet path is untouched (Rule #11). Shared with `.zashiSelectorSheet`.
    @ViewBuilder func macSheetCardSurface() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(in: RoundedRectangle(cornerRadius: Design.Radius._4xl))
        } else {
            self
                .background(Asset.Colors.background.color)
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius._4xl))
        }
    }
}
#endif

extension View {
    func zashiSheet(
        isPresented: Binding<Bool>,
        horizontalPadding: CGFloat = Design.Spacing._3xl,
        dragIndicatorVisibility: Visibility = .visible,
        onDismiss: (() -> Void)? = nil,
        content: @escaping () -> some View
    ) -> some View {
        modifier(
            ZashiSheetModifier(
                isPresented: isPresented,
                horizontalPadding: horizontalPadding,
                dragIndicatorVisibility: dragIndicatorVisibility,
                onDismiss: onDismiss,
                // PERCEPTION (MODALS.md Rule #5b): wrap the content in WithPerceptionTracking so it stays
                // reactive when rendered DETACHED in the macOS root card (MacCard), where it observes store
                // state OUTSIDE the presenting view's tracking scope. Without it, a tap updates the state
                // but the card keeps drawing the stale snapshot (e.g. filter chips never toggle, reset
                // doesn't clear them). iOS re-renders via the native sheet's parent propagation regardless;
                // wrapping is behaviour-neutral there. One wrap here covers every `.zashiSheet` dialog.
                sheetContent: { WithPerceptionTracking { content() } }
            )
        )
    }
}
