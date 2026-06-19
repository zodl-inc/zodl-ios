//
//  zodlmac_internalApp.swift
//  zodlmac-internal
//
//  macOS app entry. Mirrors the iOS `SecantApp` (AppDelegate is iOS-only, so the root store is
//  created here and the launch / foreground / background lifecycle is driven via scenePhase).
//

import SwiftUI
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
        WindowGroup {
            RootView(
                store: rootStore,
                tokenName: TargetConstants.tokenName,
                networkType: TargetConstants.zcashNetwork.networkType
            )
            .font(.custom(FontFamily.Inter.regular.name, size: 17))
            // macOS gives every default-styled Button a bezeled gray background; iOS doesn't.
            // Force plain app-wide so buttons render only their own (iOS) styling — custom
            // ZashiButton backgrounds stay, raw icon/text buttons go flat like on iOS.
            .buttonStyle(.plain)
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
