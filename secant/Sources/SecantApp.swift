//
//  secantApp.swift
//  secant
//
//  Created by Francisco Gindre on 7/29/21.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import Flexa

@main
struct SecantApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @Shared(.inMemory(.featureFlags)) var featureFlags: FeatureFlags = .initial

    init() {
        FontFamily.registerAllCustomFonts()
        setupFeatureFlags()
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                store: appDelegate.rootStore,
                tokenName: TargetConstants.tokenName,
                networkType: TargetConstants.zcashNetwork.networkType
            )
            .font(
                .custom(FontFamily.Inter.regular.name, size: 17)
            )
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                appDelegate.rootStore.send(.initialization(.appDelegate(.willEnterForeground)))
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                appDelegate.rootStore.send(.initialization(.appDelegate(.didEnterBackground)))
                appDelegate.scheduleBackgroundTask()
                appDelegate.scheduleSchedulerBackgroundTask()
            }
            .onOpenURL { url in
                if featureFlags.flexa {
                    Flexa.processUniversalLink(url: url)
                }
            }
        }
    }
}

// MARK: Zcash Network global type

/// Whenever the ZcashNetwork is required use this var to determine which is the
/// network type suitable for the present target.

enum TargetConstants {
    static var zcashNetwork: ZcashNetwork {
#if SECANT_MAINNET
    return ZcashNetworkBuilder.network(for: .mainnet)
#elseif SECANT_TESTNET
    return ZcashNetworkBuilder.network(for: .testnet)
#else
    fatalError("SECANT_MAINNET or SECANT_TESTNET flags not defined on Swift Compiler custom flags of your build target.")
#endif
    }
    
    static var tokenName: String {
#if SECANT_MAINNET
    return "ZEC"
#elseif SECANT_TESTNET
    return "TAZ"
#else
    fatalError("SECANT_MAINNET or SECANT_TESTNET flags not defined on Swift Compiler custom flags of your build target.")
#endif
    }
}

extension SecantApp {
    func setupFeatureFlags() {
#if SECANT_DISTRIB
        $featureFlags.withLock { $0 = FeatureFlags() }
#elseif SECANT_TESTNET
        $featureFlags.withLock {
            $0 = FeatureFlags(
                appLaunchBiometric: true,
                flexa: true
            )
        }
#else
        $featureFlags.withLock {
            $0 = FeatureFlags(
                appLaunchBiometric: true,
                flexa: true
            )
        }
#endif
    }
}
