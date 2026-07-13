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

    /// Authenticate, showing `reason` in the OS prompt. macOS composes it as "Zodl is trying to {reason}",
    /// so `reason` must be a verb phrase — use `authenticate(for:)` / `AuthenticationContext` rather than
    /// calling this directly, so the prompt says what the action actually is.
    var authenticate: @Sendable (_ reason: String) async -> Bool = { _ in false }
    var method: @Sendable () -> Method = { .none }
}

/// The action a biometric / passcode prompt is gating. Selects the user-facing reason so each prompt says
/// what is actually happening — unlocking the app and authorizing a send are very different, and a single
/// "unlock your wallet" for both reads as wrong (macOS composes "Zodl is trying to {reason}"; iOS shows the
/// reason on the prompt). Add a case + a `localAuthentication.reason.*` string to extend.
enum AuthenticationContext: Equatable {
    case appUnlock
    case sendFunds
    case revealRecoveryPhrase
    case addressBook
    case exportData
    case vote
    case settings

    var localizedReason: String {
        switch self {
        case .appUnlock: return String(localizable: .localAuthenticationReasonUnlock)
        case .sendFunds: return String(localizable: .localAuthenticationReasonSend)
        case .revealRecoveryPhrase: return String(localizable: .localAuthenticationReasonRevealPhrase)
        case .addressBook: return String(localizable: .localAuthenticationReasonAddressBook)
        case .exportData: return String(localizable: .localAuthenticationReasonExportData)
        case .vote: return String(localizable: .localAuthenticationReasonVote)
        case .settings: return String(localizable: .localAuthenticationReasonSettings)
        }
    }
}

extension LocalAuthenticationClient {
    /// App-level biometric / passcode gate, with a context-appropriate prompt reason.
    func authenticate(for context: AuthenticationContext) async -> Bool {
        await authenticate(context.localizedReason)
    }

    /// Authentication for an action that immediately decrypts the seed via the Secure Enclave (send, view
    /// phrase, swap/pay, vote, Flexa). On macOS that SE decrypt is itself a `.userPresence` biometric gate,
    /// so prompting here too would be a redundant SECOND biometric — skip the app-level prompt and let the
    /// SE decrypt be the single auth (pass the same `context` to `exportWallet(reason:)` so that prompt is
    /// context-aware). iOS has no SE seed-wrap, so it keeps this as the only gate, prompting with `context`.
    /// (Keystone spends sign via PCZT and never reach these seed-decrypt call sites, so this never removes a
    /// hardware wallet's only auth.)
    func authenticateForSeedDecrypt(for context: AuthenticationContext) async -> Bool {
        #if os(macOS)
        return true
        #else
        return await authenticate(for: context)
        #endif
    }
}
