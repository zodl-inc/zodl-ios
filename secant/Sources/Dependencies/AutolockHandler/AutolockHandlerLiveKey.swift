//
//  AutolockHandlerLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 06-10-2024.
//

import ComposableArchitecture
import UIKit

extension AutolockHandlerClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        return Self(
            value: { @MainActor isRestoring in
                UIDevice.current.isBatteryMonitoringEnabled = true
                AutolockHandlerClient.handleAutolock(isRestoring)
            },
            batteryStatePublisher: {
                NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)
            }
        )
    }
}

private extension AutolockHandlerClient {
    @MainActor static func handleAutolock(_ isRestoring: Bool) -> Void {
        switch UIDevice.current.batteryState {
        case .charging, .full:
            UIApplication.shared.isIdleTimerDisabled = isRestoring
        case .unplugged, .unknown:
            UIApplication.shared.isIdleTimerDisabled = false
        @unknown default:
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
