//
//  SharedLiveEscrow.swift
//  zodlTests
//
//  Mutual exclusion for tests that drive the REAL file-backed escrow.
//
//  The live escrow writes one fixed path in Documents, so any two tests using
//  it share mutable process-wide state. Swift Testing runs suites in parallel
//  and `.serialized` only orders tests WITHIN one suite, so suites that both
//  reach the live escrow interleave and clobber each other -- observed as
//  `openingTheAppTwiceLeavesTheEscrowUnchanged` failing in a full-target run
//  while passing when its suite runs alone.
//
//  Trait inheritance across a nested suite was tried first and did not hold.
//  An explicit lock does not depend on how the runner discovers suites or
//  propagates traits, which is why it is the one used.
//

import Foundation

/// Serialises everything that touches the live delegation escrow.
///
/// Wrap the WHOLE body of such a test, including its planting and its
/// assertions: releasing between the write and the read would put the shared
/// file back in play exactly where it matters.
///
///     @Test func something() async throws {
///         try await SharedLiveEscrow.exclusive {
///             ...
///         }
///     }
enum SharedLiveEscrow {
    private actor Gate {
        private var busy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !busy {
                busy = true
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            if waiting.isEmpty {
                busy = false
            } else {
                waiting.removeFirst().resume()
            }
        }
    }

    private static let gate = Gate()

    /// `isolation: #isolation` makes the body run in the CALLER's isolation
    /// rather than crossing into this type. Without it a `@MainActor` test
    /// body is a non-Sendable closure being sent across an actor boundary,
    /// which Swift 6 rejects -- and making it `@Sendable` instead would be a
    /// lie about state the test legitimately holds on the main actor.
    static func exclusive<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        await gate.acquire()
        defer { Task { await gate.release() } }
        return try await body()
    }
}
