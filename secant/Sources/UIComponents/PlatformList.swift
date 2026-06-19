//
//  PlatformList.swift
//  modules
//
//  macOS draws a `List` with its own scroll backing behind/below the rows; iOS doesn't.
//  Hide it on macOS so the screen / listRow background shows through (matching iOS). No-op on iOS.
//

import SwiftUI

extension View {
    @ViewBuilder
    func zashiHideListBackground() -> some View {
#if os(macOS)
        scrollContentBackground(.hidden)
#else
        self
#endif
    }

    /// macOS: phone-width content centered in the window with a small vertical inset and the app
    /// background filling the wide horizontal margins — for single-view flows (onboarding/restore).
    /// No-op on iOS.
    @ViewBuilder
    func macOSSingleViewLayout() -> some View {
#if os(macOS)
        ZStack {
            Asset.Colors.background.color.ignoresSafeArea()
            self
                .frame(maxWidth: 460, maxHeight: .infinity)
                .padding(.vertical, 16)
        }
#else
        self
#endif
    }
}
