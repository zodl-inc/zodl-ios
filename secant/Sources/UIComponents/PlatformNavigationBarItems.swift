//
//  PlatformNavigationBarItems.swift
//  Zashi
//
//  `.navigationBarItems(leading:/trailing:)` is unavailable on macOS. This shim keeps call sites
//  unchanged across platforms: iOS uses the (deprecated but functional) navigationBarItems; macOS
//  maps to a toolbar item so the buttons still render.
//

import SwiftUI

extension View {
    @ViewBuilder
    func zashiNavigationBarItems<T: View>(trailing: T) -> some View {
#if os(iOS)
        navigationBarItems(trailing: trailing)
#else
        toolbar { ToolbarItem(placement: .primaryAction) { trailing } }
#endif
    }

    @ViewBuilder
    func zashiNavigationBarItems<L: View>(leading: L) -> some View {
#if os(iOS)
        navigationBarItems(leading: leading)
#else
        toolbar { ToolbarItem(placement: .navigation) { leading } }
#endif
    }
}
