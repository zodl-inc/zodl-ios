#if VOTING_ENABLED
//
//  VotingBundleTrimmingTests.swift
//  zodlTests
//

import Foundation
import Testing
@testable import zodl_internal

/// The privacy trim mirrors the Android app's rule: pop the cheapest value-descending bundles while
/// the accumulated dropped raw weight stays within the smaller of 1 % of the total and 1,000 ZEC,
/// never below two bundles.
@Suite(.timeLimit(.minutes(3))) struct VotingBundleTrimmingTests {
    private let zec: UInt64 = 100_000_000

    @Test func twoOrFewerBundlesAreNeverTrimmed() {
        #expect(VotingBundleTrimPolicy.keepCount(rawWeights: []) == 0)
        #expect(VotingBundleTrimPolicy.keepCount(rawWeights: [5 * zec]) == 1)
        #expect(VotingBundleTrimPolicy.keepCount(rawWeights: [5 * zec, 1]) == 2)
    }

    @Test func theTailIsDroppedWhileItFitsInOnePercentOfTheTotal() {
        // 9000 + 890 + 60 + 50 = 10,000 ZEC: the budget is 100 ZEC. The 50 fits, 50 + 60 does not.
        let weights = [9_000 * zec, 890 * zec, 60 * zec, 50 * zec]
        #expect(VotingBundleTrimPolicy.keepCount(rawWeights: weights) == 3)
    }

    @Test func aDropLandingExactlyOnTheBudgetIsTaken() {
        // 9000 + 900 + 60 + 40 = 10,000 ZEC: budget 100 ZEC, and 40 + 60 is exactly 100.
        let weights = [9_000 * zec, 900 * zec, 60 * zec, 40 * zec]
        #expect(VotingBundleTrimPolicy.keepCount(rawWeights: weights) == 2)
    }

    @Test func theBudgetIsCappedAtOneThousandZec() {
        // 1 % of 1,000,000 ZEC would be 10,000 ZEC; the cap is 1,000 ZEC, so 600 fits and 600 + 500 does not.
        let weights = [998_900 * zec, 1_100 * zec, 600 * zec, 500 * zec].sorted(by: >)
        #expect(VotingBundleTrimPolicy.keepCount(rawWeights: weights) == 3)
    }

    @Test func theTrimNeverGoesBelowTwoBundles() {
        // A generous budget relative to the tail still leaves two bundles standing.
        let weights = [1_000 * zec, 1, 1, 1]
        #expect(VotingBundleTrimPolicy.keepCount(rawWeights: weights) == 2)
    }

    @Test func theSwitchRestoresTheUntrimmedCount() {
        let weights = [9_000 * zec, 890 * zec, 60 * zec, 50 * zec]
        #expect(VotingBundleTrimPolicy.keepCount(rawWeights: weights, isEnabled: false) == 4)
    }
}
#endif
