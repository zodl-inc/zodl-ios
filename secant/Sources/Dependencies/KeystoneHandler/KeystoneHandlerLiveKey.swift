//
//  KeystoneHandlerLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-11-20.
//

import ComposableArchitecture
@preconcurrency import KeystoneSDK
import Atomics

final class KeystoneSDKWrapper: Sendable {
    let keystoneSDK = KeystoneSDK()
    let foundResult = ManagedAtomic<Bool>(false)

    func decodeQR(_ qrCode: String) -> DecodeResult? {
        guard !foundResult.load(ordering: .acquiring) else { return nil }

        let result = try? keystoneSDK.decodeQR(qrCode: qrCode)

        foundResult.store(result?.progress == 100, ordering: .releasing)

        return result
    }

    func resetQRDecoder() {
        foundResult.store(false, ordering: .releasing)
        keystoneSDK.resetQRDecoder()
    }
}

extension KeystoneHandlerClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        let wrapper = KeystoneSDKWrapper()

        return .init(
            decodeQR: { wrapper.decodeQR($0) },
            resetQRDecoder: { wrapper.resetQRDecoder() }
        )
    }
}
