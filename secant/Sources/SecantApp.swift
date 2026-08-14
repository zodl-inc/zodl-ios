//
//  secantApp.swift
//  secant
//
//  Created by Francisco Gindre on 7/29/21.
//

#if os(iOS)
import SwiftUI
import Combine
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

extension SecantApp {
    func setupFeatureFlags() {
#if SECANT_DISTRIB
        $featureFlags.withLock { $0 = FeatureFlags() }
#elseif SECANT_TESTNET
        $featureFlags.withLock {
            $0 = FeatureFlags(
                appLaunchBiometric: true,
                flexa: true,
                migration: true
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
#endif
