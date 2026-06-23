//
//  ZashiSheet.swift
//  modules
//
//  Created by Lukáš Korba on 31.03.2025.
//

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
    var sheetContent: SheetContent

    func body(content: Content) -> some View {
#if os(macOS)
        // macOS doesn't support iOS `presentationDetents` (they collapse the sheet to 0 height)
        // and honors only one `.sheet` per view — so the app's stacked, custom-styled zashiSheets
        // can't use a native sheet. Present a centered, content-sized card as an overlay instead:
        // overlays stack freely, the card hugs its content height (sheets vary in size), and it gets
        // an explicit close button plus click-outside / ESC dismissal.
        content
            .overlay {
                if isPresented {
                    macOSSheetOverlay()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: isPresented)
            .onChange(of: isPresented) { _, newValue in
                if !newValue { onDismiss?() }
            }
#else
        content
            .sheet(isPresented: $isPresented, onDismiss: onDismiss) {
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
#endif
    }

#if os(macOS)
    @ViewBuilder func macOSSheetOverlay() -> some View {
        ZStack {
            // Dimmed backdrop — click anywhere outside the card to dismiss.
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            // Card: width-capped, height follows the content (sheets vary in size).
            VStack(alignment: .leading, spacing: 0) {
                sheetContent
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, Design.Spacing._3xl)
            .frame(maxWidth: 480)
            .fixedSize(horizontal: false, vertical: true)
            // RULE #5: the macOS dynamic-content card surface is Liquid Glass (was a solid color).
            .macSheetCardSurface()
            .overlay(alignment: .topTrailing) {
                Button {
                    isPresented = false
                } label: {
                    Asset.Assets.buttonCloseX.image
                        .zImage(size: 24, style: Design.Text.primary)
                        .padding(Design.Spacing._lg)
                }
                .zashiPlainButtonStyle()
                .keyboardShortcut(.cancelAction)
            }
            .shadow(color: Color.black.opacity(0.25), radius: 24, x: 0, y: 10)
            .padding(40)
        }
    }
#endif

    @ViewBuilder func mainBody(stickToBottom: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if stickToBottom {
               Spacer()
            }

            sheetContent
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

            sheetContent
        }
        .readHeight { height in
            if abs(height - sheetHeight) > 1 {
                sheetHeight = height
            }
        }
    }
}

#if os(macOS)
private extension View {
    /// RULE #5: the macOS sheet card surface is Liquid Glass (macOS 26+), with a solid fallback below.
    /// macOS-only — the iOS sheet path is untouched (Rule #11).
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
                sheetContent: content()
            )
        )
    }
}
