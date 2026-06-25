//
//  zodlmac_internalApp.swift
//  zodlmac-internal
//
//  macOS app entry. Mirrors the iOS `SecantApp` (AppDelegate is iOS-only, so the root store is
//  created here and the launch / foreground / background lifecycle is driven via scenePhase).
//

import SwiftUI
import AppKit
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@main
struct zodlmac_internalApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @Shared(.inMemory(.featureFlags)) var featureFlags: FeatureFlags = .initial
    @State private var didFinishLaunching = false
    @State private var didEnterBackgroundOnce = false

    let rootStore = StoreOf<Root>(
        initialState: .initial
    ) {
        Root()
//            .logging()
    }

    init() {
        FontFamily.registerAllCustomFonts()
        NSDecimalNumber.defaultBehavior = Zatoshi.decimalHandler
        setupFeatureFlags()
    }

    var body: some Scene {
        // Empty window title: macOS uses the window title as the navigation fallback, which surfaced as a
        // non-contextual "← Zodl" on every back button. Blank it for Beta (screens can set their own
        // contextual navigationTitle later — e.g. "← Vote"). The app name in the dock/menu is the bundle
        // name, unaffected.
        WindowGroup("") {
            RootView(
                store: rootStore,
                tokenName: TargetConstants.tokenName,
                networkType: TargetConstants.zcashNetwork.networkType
            )
            .frame(width: WindowSize.width, height: WindowSize.height)
            .background(FixedWindowConfigurator())
            .font(.custom(FontFamily.Inter.regular.name, size: 17))
            // macOS gives every default-styled Button a bezeled gray background; iOS doesn't.
            // Force plain app-wide so buttons render only their own (iOS) styling — custom
            // ZashiButton backgrounds stay, raw icon/text buttons go flat like on iOS.
            .zashiPlainButtonStyle()
            // Same story for text fields: macOS draws a native bezel/inset; iOS is borderless and
            // the app supplies its own background + padding. Force plain so inputs match iOS.
            .textFieldStyle(.plain)
            .onAppear {
                guard !didFinishLaunching else { return }
                didFinishLaunching = true
                rootStore.send(.initialization(.appDelegate(.didFinishLaunching)))
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    // iOS only fires willEnterForeground when returning from the background —
                    // NOT at cold launch, where didFinishLaunching already runs initialSetups.
                    // Without this guard the first `.active` runs initialSetups a second time →
                    // a second engine handle → SQLite "database is locked" and a racing sync
                    // that drops transactions and balance.
                    if didEnterBackgroundOnce {
                        rootStore.send(.initialization(.appDelegate(.willEnterForeground)))
                    }
                case .background:
                    didEnterBackgroundOnce = true
                    rootStore.send(.initialization(.appDelegate(.didEnterBackground)))
                default:
                    break
                }
            }
        }
        .windowResizability(.contentSize)
    }
}

private extension zodlmac_internalApp {
    func setupFeatureFlags() {
        // macOS: Flexa package is excluded; biometric (Touch ID) is supported.
        $featureFlags.withLock {
            $0 = FeatureFlags(
                appLaunchBiometric: true,
                flexa: false
            )
        }
    }
}

private enum WindowSize {
    // Fixed landscape window for the macOS split layout — sourced from the single Mac sizing
    // namespace so the whole app resizes from one place (Design.Mac).
    static let width: CGFloat = Design.Mac.windowWidth
    static let height: CGFloat = Design.Mac.windowHeight
}

/// Locks the macOS window to a fixed size and disables the full-screen (green) button, so the
/// iOS phone layout always renders at its intended proportions.
private struct FixedWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.remove(.resizable)
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            // Lock the content size so a screen with tall, unconstrained content (e.g. the voting
            // "how to vote" screen) can't grow the window (which also enlarged the sidebar). With the
            // size locked, such a screen is clamped to the fixed pane and its ScrollView scrolls instead.
            let fixedContent = NSSize(width: WindowSize.width, height: WindowSize.height)
            window.contentMinSize = fixedContent
            window.contentMaxSize = fixedContent
            // Always open CENTERED on the active screen — never restore a remembered (often too-low /
            // partially-offscreen) position. Disable frame autosave, then center within `visibleFrame`
            // (which excludes the menu bar + Dock). Deferred so we win against SwiftUI's restore.
            window.setFrameAutosaveName("")
            DispatchQueue.main.async { [weak window] in
                guard let window, let screen = window.screen ?? NSScreen.main else { return }
                let visible = screen.visibleFrame
                let size = window.frame.size
                window.setFrameOrigin(
                    NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
                )
            }
        }
    }
}
