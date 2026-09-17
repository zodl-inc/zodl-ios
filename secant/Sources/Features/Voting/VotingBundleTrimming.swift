#if VOTING_ENABLED
//
//  VotingBundleTrimming.swift
//  Zashi
//

import Foundation

/// The privacy trim of a round's note bundles, the same rule the Android app applies.
///
/// Bundles hold five notes with no cap, so a wallet whose value sits in a few large notes plus a
/// long dust tail produces many bundles that carry almost no voting weight, and every bundle costs
/// one delegation proof plus one vote proof and one poll-until-mined wait per question. Bundles
/// are value-descending, so the trim pops the cheapest tail bundles while the accumulated dropped
/// raw weight stays within the budget, never going below `maxPrivacyBundles`.
///
/// `isEnabled` is a compile-time switch: `false` restores the untrimmed behaviour without touching
/// any call site.
enum VotingBundleTrimPolicy {
    static let isEnabled = true

    /// Bundle count the trim aims for whenever the drop budget can pay for it.
    static let maxPrivacyBundles = 2

    /// Share of the summed raw bundle weight the trim may discard, in basis points (100 = 1 %).
    static let dropBasisPoints: UInt64 = 100

    /// Absolute ceiling on the discarded raw weight: 1,000 ZEC, in zatoshi.
    static let maxDropZatoshi: UInt64 = 100_000_000_000

    static let basisPointsDenominator: UInt64 = 10_000

    /// How many of the value-descending `rawWeights` bundles to keep. A drop that lands exactly on
    /// the budget is taken; one that would exceed it stops the loop.
    static func keepCount(rawWeights: [UInt64], isEnabled: Bool = isEnabled) -> Int {
        let minimum = max(maxPrivacyBundles, 1)
        guard isEnabled, rawWeights.count > minimum else {
            return rawWeights.count
        }
        let total = rawWeights.reduce(UInt64(0), +)
        let budget = min(total * dropBasisPoints / basisPointsDenominator, maxDropZatoshi)

        var keep = rawWeights.count
        var dropped: UInt64 = 0
        while keep > minimum {
            let last = rawWeights[keep - 1]
            if dropped + last > budget {
                break
            }
            dropped += last
            keep -= 1
        }
        return keep
    }
}

/// How a fresh bundle setup was trimmed: `keepCount` bundles survive with `keptWeight` of
/// quantized voting weight; `trimmedBundleCount` bundles carrying `trimmedWeight` were dropped.
struct VotingBundleTrim: Equatable, Sendable {
    let keepCount: UInt32
    let keptWeight: UInt64
    let trimmedBundleCount: UInt32
    let trimmedWeight: UInt64
}
#endif
