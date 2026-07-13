//
//  PlatformScreen.swift
//  Zashi
//
//  Cross-platform screen helpers. iOS uses `UIScreen`; macOS uses `NSScreen` for bounds and
//  no-ops brightness control (there is no per-app screen-brightness API on macOS).
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum PlatformScreen {
    static var bounds: CGRect {
#if canImport(UIKit)
        UIScreen.main.bounds
#elseif canImport(AppKit)
        NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
#else
        CGRect(x: 0, y: 0, width: 1440, height: 900)
#endif
    }

    static var brightness: CGFloat {
        get {
#if canImport(UIKit)
            UIScreen.main.brightness
#else
            1.0
#endif
        }
        set {
#if canImport(UIKit)
            UIScreen.main.brightness = newValue
#else
            _ = newValue // macOS: no per-app brightness control
#endif
        }
    }
}
