//
//  PlatformIdleTimer.swift
//  Zashi
//
//  Cross-platform "prevent screen sleep" toggle. iOS uses UIApplication's idle timer;
//  macOS has no per-app idle timer (display sleep is system-managed), so it's a no-op.
//

#if os(iOS)
import UIKit
#endif

@MainActor
enum PlatformIdleTimer {
    static var disabled: Bool {
        get {
#if os(iOS)
            UIApplication.shared.isIdleTimerDisabled
#else
            false
#endif
        }
        set {
#if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = newValue
#else
            _ = newValue // macOS: no per-app idle timer
#endif
        }
    }
}
