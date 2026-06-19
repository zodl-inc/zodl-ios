//
//  PlatformNavigation.swift
//  secant
//
//  Cross-platform shims for iOS-only SwiftUI navigation APIs, so the shared view code
//  compiles on macOS. Behavior is best-effort (no-op / nearest macOS equivalent); a proper
//  native-macOS navigation/toolbar pass is a later (layout) milestone.
//

import SwiftUI

enum ZashiTitleDisplayMode {
    case automatic, inline, large
#if os(iOS)
    var value: NavigationBarItem.TitleDisplayMode {
        switch self {
        case .automatic: return .automatic
        case .inline: return .inline
        case .large: return .large
        }
    }
#endif
}

extension View {
    /// iOS: maps to `navigationBarTitleDisplayMode`. macOS: no-op.
    func zashiNavBarTitleDisplayMode(_ mode: ZashiTitleDisplayMode) -> some View {
#if os(iOS)
        return self.navigationBarTitleDisplayMode(mode.value)
#else
        return self
#endif
    }

    /// iOS: `.navigationViewStyle(.stack)`. macOS: no-op.
    func zashiStackNavigationStyle() -> some View {
#if os(iOS)
        return self.navigationViewStyle(.stack)
#else
        return self
#endif
    }
}

extension ToolbarItemPlacement {
    /// iOS: `.navigationBarLeading`. macOS: `.navigation` (top-left, by the window controls).
    static var zashiLeading: ToolbarItemPlacement {
#if os(iOS)
        return .navigationBarLeading
#else
        return .navigation
#endif
    }

    /// iOS: `.navigationBarTrailing`. macOS: `.automatic`.
    static var zashiTrailing: ToolbarItemPlacement {
#if os(iOS)
        return .navigationBarTrailing
#else
        return .automatic
#endif
    }
}
