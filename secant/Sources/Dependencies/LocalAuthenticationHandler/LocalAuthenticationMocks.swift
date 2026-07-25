//
//  LocalAuthenticationMocks.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.11.2022.
//

import ComposableArchitecture

extension LocalAuthenticationClient {
    static let mockAuthenticationSucceeded = Self(
        authenticate: { true },
        method: { .none }
    )

    static let mockAuthenticationFailed = Self(
        authenticate: { false },
        method: { .none }
    )

    /// MOB-1458: counts `authenticate()` calls, then answers `result`. For tests that need to prove
    /// a tap prompted exactly once — or, with `result: false`, that a refusal unwinds cleanly.
    /// Previously hand-rolled at every such call site.
    ///
    /// To prove a path never prompts AT ALL, do not use this: leave `localAuthentication`
    /// unimplemented in `withDependencies` instead, so any call reports a test failure by itself.
    static func mockAuthenticationCounting(_ calls: LockIsolated<Int>, result: Bool = true) -> Self {
        Self(
            authenticate: {
                calls.withValue { $0 += 1 }
                return result
            },
            method: { .none }
        )
    }

    /// MOB-1458: counts `authenticate()` calls and then BLOCKS until `releaseStream` yields, so a
    /// test can hold the prompt open and drive what happens underneath it — a second tap landing on
    /// the single-flight guard, or a propose resolving mid-prompt (the round-2 regression pin).
    /// Yield to or finish the stream to let authentication answer `result`.
    static func mockAuthenticationBlocking(
        _ calls: LockIsolated<Int>,
        releaseStream: AsyncStream<Void>,
        result: Bool = true
    ) -> Self {
        Self(
            authenticate: {
                calls.withValue { $0 += 1 }
                for await _ in releaseStream {
                    break
                }
                return result
            },
            method: { .none }
        )
    }
}
