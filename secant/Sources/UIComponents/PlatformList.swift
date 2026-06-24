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
}
