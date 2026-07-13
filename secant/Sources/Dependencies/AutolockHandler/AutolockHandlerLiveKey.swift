//
//  AutolockHandlerLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 06-10-2024.
//

import ComposableArchitecture
import Foundation
#if canImport(UIKit)
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
            PlatformIdleTimer.disabled = isRestoring
        case .unplugged, .unknown:
            PlatformIdleTimer.disabled = false
        @unknown default:
            PlatformIdleTimer.disabled = false
        }
    }
}
#else
extension AutolockHandlerClient: DependencyKey {
    // macOS: no UIDevice battery / idle-timer control.
    static let liveValue = Self(
        value: { _ in },
        batteryStatePublisher: { NotificationCenter.default.publisher(for: Notification.Name("co.zodl.macos.autolock.noop")) }
    )
}
#endif
