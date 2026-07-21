//
//  MigrationRandomnessTests.swift
//  zodlTests
//
//  Covers `MigrationRandomnessClient` (Dependencies/MigrationRandomness/) — MOB-1497 (R7): the
//  test-controllable randomness seam behind the migration snapshot's uniform-random broadcast-
//  endpoint pick. `MigrationManagerTests` covers the CONSUMER (`createNetworkSnapshot`) against a
//  seeded mock; this file covers the LIVE generator itself.
//

import Testing

@testable import zodl_internal

struct MigrationRandomnessTests {
    @Test func liveRandomIndexStaysWithinBoundsAcrossManyDraws() {
        let live = MigrationRandomnessClient.liveValue

        for _ in 0..<200 {
            let index = live.randomIndex(5)
            #expect(index >= 0 && index < 5)
        }
    }

    @Test func liveRandomIndexWithASingleCandidateAlwaysReturnsZero() {
        let live = MigrationRandomnessClient.liveValue

        #expect(live.randomIndex(1) == 0)
    }
}
