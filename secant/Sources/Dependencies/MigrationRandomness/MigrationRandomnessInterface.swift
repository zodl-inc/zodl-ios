//
//  MigrationRandomnessInterface.swift
//  Zashi
//
//  Minimal injectable randomness seam (MOB-1497 — R7's uniform-random broadcast-endpoint pick, which
//  replaces the old benchmark-based selection in `MigrationManagerLiveKey.createNetworkSnapshot`).
//  There was no existing house RNG seam to reuse: nothing else in the app injects randomness.
//
//  Exposes exactly the one primitive `createNetworkSnapshot` needs — a uniformly random index into a
//  non-empty candidate list — rather than a raw `RandomNumberGenerator`. A raw generator is awkward
//  as a stored `@Sendable` closure dependency: `RandomNumberGenerator.next()` mutates by reference,
//  which doesn't fit the value-semantics, call-and-return shape every other client member here uses.
//

import Foundation
import ComposableArchitecture

extension DependencyValues {
    var migrationRandomness: MigrationRandomnessClient {
        get { self[MigrationRandomnessClient.self] }
        set { self[MigrationRandomnessClient.self] = newValue }
    }
}

@DependencyClient
struct MigrationRandomnessClient: Sendable {
    /// A uniformly random index in `0..<count`. Callers guarantee `count > 0` (a non-empty candidate
    /// list) before calling — an empty range traps, same as `Int.random(in:)` itself. `= { _ in 0 }`
    /// is a placeholder default (deterministic, not random), not a live implementation — see
    /// `MigrationRandomnessLiveKey.swift` for the real generator. Tests that care about the pick
    /// override this member with a fixed value or a seeded generator for reproducibility.
    var randomIndex: @Sendable (_ count: Int) -> Int = { _ in 0 }
}
