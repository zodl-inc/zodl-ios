//
//  KeystoneHandlerInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-11-20.
//

import ComposableArchitecture
@preconcurrency import KeystoneSDK

extension DependencyValues {
    var keystoneHandler: KeystoneHandlerClient {
        get { self[KeystoneHandlerClient.self] }
        set { self[KeystoneHandlerClient.self] = newValue }
    }
}

@DependencyClient
struct KeystoneHandlerClient {
    var decodeQR: @Sendable (String) -> DecodeResult?
    var resetQRDecoder: @Sendable () -> Void
}
