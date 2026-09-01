//
//  SeededGenerator.swift
//  zodlTests
//
//  Reproducible randomness for tests.
//
//  General-purpose, and deliberately NOT gated on VOTING_ENABLED or tied to
//  any one suite: it was extracted from the delegation-recovery fixture, which
//  needs filler bytes that vary per run yet can be replayed exactly when a run
//  fails, but nothing here knows about that fixture.
//
//  The pattern it supports:
//
//      let seed = UInt64.random(in: .min ... .max)   // vary per run
//      print("[fixture] seed \(seed)")               // so CI can replay it
//      var rng = SeededGenerator(seed: seed)
//      let byte = UInt8.random(in: 0...255, using: &rng)
//
//  Randomising is what makes the test sample a new arrangement each run, and
//  logging the seed is what stops that costing reproducibility. One without
//  the other is either a fixed sample or an unreproducible failure.
//

import Foundation

/// A seedable `RandomNumberGenerator`, because the Swift standard library has
/// none: `SystemRandomNumberGenerator` cannot be seeded, so a reproducible
/// stream has to be supplied by hand. splitmix64 is small, well distributed,
/// and is the generator the SplitMix and xoshiro families use to seed
/// themselves.
///
/// Conforming to the protocol rather than emitting bytes by hand means the
/// ordinary APIs work: `UInt8.random(in:using:)`, `shuffled(using:)`, and the
/// rest.
///
/// NOT for anything security-relevant. This is a test-fixture generator; keys,
/// nonces and salts come from `crypto/rand`-grade sources.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // A zero state would emit a constant stream.
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension String {
    /// A process-independent hash, for deriving one substream per name from a
    /// single run seed (`seed ^ "label".stableHash`).
    ///
    /// `hashValue` cannot be used for this. Swift seeds it per process, so the
    /// same label would give a different stream in every run even at a fixed
    /// seed — the failure would not replay, which is the whole point of
    /// carrying a seed. FNV-1a is stable across processes and runs.
    ///
    /// Not a cryptographic hash, and not meant to be.
    var stableHash: UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
