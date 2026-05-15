//
//  LocalAuthenticationLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.11.2022.
//

import ComposableArchitecture
import LocalAuthentication

extension LocalAuthenticationClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            authenticate: {
#if targetEnvironment(simulator)
                return true
#endif
                let context = LAContext()
                var error: NSError?
                let reason = String(localizable: .localAuthenticationReason)

                do {
                    /// Biometrics validation
                    if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
                        return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
                    } else {
                        /// Biometrics not supported by the device, fallback to passcode
                        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
                            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                        } else {
                            /// No local authentication available, user's device is not protected, fallback to allow access to sensitive content
                            return true
                        }
                    }
                } catch {
                    /// Some interruption occurred during the authentication, access to the sensitive content is therefore forbidden
                    return false
                }
            },
            method: {
                let context = LAContext()
                var error: NSError?

                if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
                    switch context.biometryType {
                    case .faceID:
                        return .faceID
                    case .touchID:
                        return .touchID
                    case .none, .opticID:
                        return .none
                    @unknown default:
                        return .none
                    }
                } else {
                    if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
                        return .passcode
                        } else {
                            return .none
                        }
                }
            }
        )
    }
}
