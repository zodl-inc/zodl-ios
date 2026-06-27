//
//  SeedScreenSecurityGuard.swift
//  Zashi
//
//  macOS seed-input hardening — v1, steps S1 + S2. See docs/macos/SEED_INPUT_SECURITY.md.
//
//  Attaching `.seedScreenSecurityGuard()` to the recovery-phrase ENTRY screen hardens it, for
//  exactly as long as that screen is on-screen, against the two software channels that matter
//  while a user types 24 secret words on macOS:
//
//    S1 — `EnableSecureEventInput()`: keystrokes are flagged secure, so a software keylogger in
//         another process (the standard `CGEventTap` technique) stops receiving them. This is the
//         same switch as Terminal's "Secure Keyboard Entry". It is a GLOBAL, session-wide mode —
//         every Enable MUST be balanced by exactly one Disable or other apps' keyboard input can
//         wedge until logout. The entire job of this type is that watertight lifecycle.
//
//    S2 — `NSWindow.sharingType = .none`: the window is excluded from the standard screen-capture
//         paths (screenshots, screen sharing, ScreenCaptureKit). One move hides the fields AND the
//         autocomplete suggestions AND which chip was tapped from screen-recording malware — which
//         is why this is preferred over masking the field with dots (the suggestions would leak
//         regardless). The window outlives the seed screen (it later shows the wallet), so the
//         previous sharing type is captured and RESTORED on the way out — never left excluded.
//
//  iOS has no analog (the platform doesn't permit third-party keystroke taps and a background app
//  can't screen-record another) and is intentionally untouched — the call site uses the no-op
//  variant below so it can attach the modifier unconditionally (platform-isolation rule).
//

import SwiftUI

extension View {
#if os(macOS)
    /// Hardens the macOS recovery-phrase ENTRY screen: secure event input (anti-keylogger, S1) +
    /// window capture-exclusion (anti screen-recording, S2), both scoped to exactly while this view
    /// is on-screen. No-op on iOS.
    func seedScreenSecurityGuard() -> some View {
        background(SeedScreenSecurityGuard())
    }
#else
    /// No-op on iOS: there is no third-party keystroke tap to defend against, so no secure-event-input
    /// scope to manage. Present so the shared seed-entry view can call the modifier unconditionally.
    func seedScreenSecurityGuard() -> some View {
        self
    }
#endif
}

#if os(macOS)
import AppKit
import Carbon.HIToolbox   // EnableSecureEventInput / DisableSecureEventInput

private struct SeedScreenSecurityGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { GuardView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // State is driven by the view's own window/active lifecycle, not by SwiftUI updates.
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // SwiftUI discards the representable on the main thread — make sure we stand down even if the
        // view's `viewDidMoveToWindow(nil)` didn't fire first. `teardown()` is idempotent.
        MainActor.assumeIsolated {
            (nsView as? GuardView)?.teardown()
        }
    }

    final class GuardView: NSView {
        private var didEnableSecureInput = false
        private var previousSharingType: NSWindow.SharingType?
        // Held weakly so we can restore the sharing type after `self.window` has gone nil on detach;
        // the app window outlives the seed screen, so this reference stays valid through teardown.
        private weak var hardenedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                startObserving()
                reconcile()
            } else {
                teardown()
            }
        }

        // No `deinit` backstop: `viewDidMoveToWindow(nil)` and `dismantleNSView` (both main-actor)
        // already balance every enable before deallocation, and process exit releases secure input
        // anyway. A `deinit` calling main-actor UI would be both warning-prone and thread-unsafe.

        private func startObserving() {
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            // Hold secure event input ONLY while frontmost: releasing it when the app deactivates
            // avoids interfering with the now-frontmost app's input (Apple's guidance), and there is
            // nothing to protect while our field isn't receiving keystrokes. Capture-exclusion (S2)
            // intentionally stays on across deactivation — a visible window can still be recorded.
            observers.append(center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.reconcile() } })
            observers.append(center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.reconcile() } })
        }

        /// Desired state, applied as balanced deltas: capture-exclusion ON while on-screen; secure
        /// event input ON while on-screen AND frontmost. Idempotent — safe to call repeatedly.
        private func reconcile() {
            let onScreen = window != nil

            if onScreen {
                applyCaptureExclusion()
            } else {
                restoreCaptureExclusion()
            }

            if onScreen && NSApp.isActive {
                enableSecureInputIfNeeded()
            } else {
                disableSecureInputIfNeeded()
            }
        }

        func teardown() {
            disableSecureInputIfNeeded()
            restoreCaptureExclusion()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
        }

        // MARK: - S1: secure event input (balanced)

        private func enableSecureInputIfNeeded() {
            guard !didEnableSecureInput else { return }
            EnableSecureEventInput()
            didEnableSecureInput = true
        }

        private func disableSecureInputIfNeeded() {
            guard didEnableSecureInput else { return }
            DisableSecureEventInput()
            didEnableSecureInput = false
        }

        // MARK: - S2: window capture-exclusion (capture original, restore on exit)

        private func applyCaptureExclusion() {
            guard let window else { return }
            if previousSharingType == nil {
                previousSharingType = window.sharingType
                hardenedWindow = window
            }
            window.sharingType = .none
        }

        private func restoreCaptureExclusion() {
            guard let previous = previousSharingType else { return }
            hardenedWindow?.sharingType = previous
            previousSharingType = nil
            hardenedWindow = nil
        }
    }
}
#endif
