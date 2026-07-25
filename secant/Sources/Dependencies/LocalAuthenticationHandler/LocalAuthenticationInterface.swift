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
            guard await authenticate() else {
                if let cancelled = cancelled() {
                    await send(cancelled)
                }
                return
            }
            await send(success())
        }
    }
}
