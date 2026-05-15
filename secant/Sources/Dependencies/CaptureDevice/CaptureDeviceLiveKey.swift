//
//  CaptureDeviceLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 11.11.2022.
//

@preconcurrency import AVFoundation
import ComposableArchitecture

extension CaptureDeviceClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        return Self(
            isAuthorized: {
                AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            },
            isTorchAvailable: {
                guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
                    return false
                }

                return videoCaptureDevice.hasTorch
            },
            torch: { isTorchOn in
                var device: AVCaptureDevice?

                if #available(iOS 17, *) {
                    device = AVCaptureDevice.userPreferredCamera
                } else {
                    let deviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTrueDepthCamera], mediaType: AVMediaType.video, position: .back)
                    device = deviceDiscoverySession.devices.first
                }
                guard let device else {
                    throw CaptureDeviceClientError.captureDevice
                }

                if device.hasTorch && device.isTorchAvailable {
                    do {
                        try device.lockForConfiguration()
                        if isTorchOn {
                            try device.setTorchModeOn(level: 1.0)
                        } else {
                            device.torchMode = .off
                        }
                        device.unlockForConfiguration()
                    } catch {
                        throw CaptureDeviceClientError.lockForConfiguration
                    }
                } else {
                    throw CaptureDeviceClientError.torchUnavailable
                }
            }

        )
    }
}
