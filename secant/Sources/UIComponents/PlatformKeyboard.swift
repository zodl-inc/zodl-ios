//
//  PlatformKeyboard.swift
//  Zashi
//
//  Cross-platform keyboard helper. iOS resigns first responder to dismiss the software
//  keyboard; macOS has no software keyboard, so it's a no-op.
//

#if os(iOS)
import UIKit
#endif

@MainActor
enum PlatformKeyboard {
    static func dismiss() {
#if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
    }
}
