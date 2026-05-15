//
//  AudioServicesLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 11.11.2022.
//

@preconcurrency import AVFoundation
import ComposableArchitecture

extension AudioServicesClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        return Self(
            systemSoundVibrate: { AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate)) }
        )
    }
}
