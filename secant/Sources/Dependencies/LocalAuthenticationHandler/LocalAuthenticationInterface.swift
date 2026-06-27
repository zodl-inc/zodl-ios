//
//  LocalAuthenticationInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.11.2022.
//

import ComposableArchitecture

extension DependencyValues {
    var localAuthentication: LocalAuthenticationClient {
        get { self[LocalAuthenticationClient.self] }
        set { self[LocalAuthenticationClient.self] = newValue }
    }
}

@DependencyClient
struct LocalAuthenticationClient {
    enum Method: Equatable {
        case faceID
        case none
        case passcode
        case touchID
    }

    var authenticate: @Sendable () async -> Bool = { false }
    var method: @Sendable () -> Method = { .none }
}

extension LocalAuthenticationClient {
    /// Authentication for an action that immediately decrypts the seed via the Secure Enclave (send, view
    /// phrase, swap/pay, vote, Flexa). On macOS that SE decrypt is itself a `.userPresence` biometric gate,
    /// so prompting here too would be a redundant SECOND biometric — skip the app-level prompt and let the
    /// SE decrypt be the single auth. iOS has no SE seed-wrap, so it keeps this as the only gate. (Keystone
    /// spends sign via PCZT and never reach these seed-decrypt call sites, so this never removes a hardware
    /// wallet's only auth.)
    func authenticateForSeedDecrypt() async -> Bool {
        #if os(macOS)
        return true
        #else
        return await authenticate()
        #endif
    }
}
