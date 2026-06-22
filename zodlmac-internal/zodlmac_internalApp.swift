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
            .logging()
    }

    init() {
        FontFamily.registerAllCustomFonts()
        NSDecimalNumber.defaultBehavior = Zatoshi.decimalHandler
        setupFeatureFlags()
    }

    var body: some Scene {
        WindowGroup("Zodl") {
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
    // Fixed landscape window for the macOS split layout. Tweak these two numbers to resize.
    static let width: CGFloat = 1120
    static let height: CGFloat = 760
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
        }
    }
}
