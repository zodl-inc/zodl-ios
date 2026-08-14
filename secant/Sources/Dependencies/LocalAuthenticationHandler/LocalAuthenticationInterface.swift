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

extension LocalAuthenticationClient {
    /// MOB-1458: the authenticate-then-proceed effect, as one call. Every sensitive tap in the app
    /// hand-rolls this same `.run` (Send, Swap, Voting, Flexa, Settings, …) and the copies have
    /// already drifted — only some capture `authenticate` explicitly, and the refusal branch
    /// variously sends an action or bare-`return`s. New call sites should use this instead.
    ///
    /// `success` is sent only when authentication passes. `cancelled` is sent when it fails or the
    /// user dismisses the prompt — pass `nil` when the caller genuinely has nothing to unwind, but
    /// prefer an action that clears whatever in-flight flag the tap set, since a refusal must never
    /// strand a spinner. A refusal is deliberately silent beyond that: no alert, no toast, no
    /// navigation. Declining is a choice, not an error.
    ///
    /// The `[authenticate]` capture is load-bearing — it keeps the closure off `self`, so the
    /// effect can't retain a dependency struct that a test may have swapped out from under it.
    /// Callers that outlive their screen should chain `.cancellable(id:)` onto the result.
    ///
    /// Both actions are `@autoclosure`, so they are BUILT inside the effect rather than captured
    /// as values. That is what lets this work for reducers whose `Action` is not itself `Sendable`
    /// — `MigrationCoordFlow.Action` carries `Path.State` on other cases, so requiring
    /// `Action: Sendable` would exclude exactly the coordinator that needs this most. Only what the
    /// expression closes over has to be `Sendable`, which is the same rule the hand-rolled
    /// `await send(.someAction(x))` sites have always followed. Call sites read unchanged.
    func gated<Action>(
        success: @escaping @autoclosure @Sendable () -> Action,
        cancelled: @escaping @autoclosure @Sendable () -> Action? = nil
    ) -> Effect<Action> {
        .run { [authenticate] send in
            // MERGE (macos-revival x main): `authenticate` now requires a `reason` (see
            // `AuthenticationContext` above) — upstream's zero-arg call no longer compiles. Pass the
            // original pre-context generic reason (`localAuthentication.reason`, unused but still in
            // the catalog on both sides) so this helper's prompt text stays byte-identical to upstream.
            guard await authenticate(String(localizable: .localAuthenticationReason)) else {
                if let cancelled = cancelled() {
                    await send(cancelled)
                }
                return
            }
            await send(success())
        }
    }
}
