//
//  ZashiSheet.swift
//  modules
//
//  Created by Lukáš Korba on 31.03.2025.
//

import Perception
import SwiftUI

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

    private var measuredDetents: Set<PresentationDetent> {
        sheetHeight > 0 ? [.height(sheetHeight)] : [.large]
    }

    func body(content: Content) -> some View {
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
                            .presentationDetents(measuredDetents)
                            .presentationDragIndicator(dragIndicatorVisibility)
                            .padding(.horizontal, horizontalPadding)
                            .applySheetBackground()
                    } else if #available(iOS 16.4, *) {
                        mainBody()
                            .id(sheetHeight)
                            .presentationDetents(measuredDetents)
                            .presentationDragIndicator(dragIndicatorVisibility)
                            .presentationCornerRadius(Design.Radius._4xl)
                            .padding(.horizontal, horizontalPadding)
                            .applySheetBackground()
                    } else if #available(iOS 16.0, *) {
                        mainBody()
                            .id(sheetHeight)
                            .presentationDetents(measuredDetents)
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
                sheetContent: content
            )
        )
    }
}
