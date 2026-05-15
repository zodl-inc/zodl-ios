//
//  AudioServicesInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 11.11.2022.
//

import ComposableArchitecture
@preconcurrency import AVFoundation

extension DependencyValues {
    var audioServices: AudioServicesClient {
        get { self[AudioServicesClient.self] }
        set { self[AudioServicesClient.self] = newValue }
    }
}

@DependencyClient
struct AudioServicesClient {
    var systemSoundVibrate: @Sendable () -> Void = { }
}
