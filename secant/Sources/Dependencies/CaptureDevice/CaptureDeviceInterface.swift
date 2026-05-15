//
//  CaptureDeviceInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 11.11.2022.
//

import ComposableArchitecture

extension DependencyValues {
    var captureDevice: CaptureDeviceClient {
        get { self[CaptureDeviceClient.self] }
        set { self[CaptureDeviceClient.self] = newValue }
    }
}

@DependencyClient
struct CaptureDeviceClient {
    enum CaptureDeviceClientError: Error {
        case authorizationStatus
        case captureDevice
        case lockForConfiguration
        case torchUnavailable
    }

    var isAuthorized: @Sendable () -> Bool = { false }
    var isTorchAvailable: @Sendable () -> Bool = { false }
    var torch: @Sendable(Bool) throws -> Void
}
