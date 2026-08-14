//
//  MigrationSyncGateFeedTests.swift
//  zodlTests
//
//  Audit 2026-08-03 (#9): the app-side gate feed keeps only the LATEST continuation, so a
//  `refreshMigrationSyncGate()` nudge landing between a subscription teardown and the next
//  subscription's install used to vanish — and the nudge sites are exactly the broadcast-failure
//  recovery paths that already stopped sync, so one lost yield stranded sync for the session.
//  The feed now SEEDS every fresh subscription with a live gate read at install, subsuming
//  whatever a dropped nudge would have said. These tests pin the seed and the ordinary push.
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
import ComposableArchitecture
@testable import zodl_internal

@Suite(.serialized) struct MigrationSyncGateFeedTests {
    private static func freshGateStorage() -> MigrationGateStorage {
        let suiteName = "MigrationSyncGateFeedTests.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        return MigrationGateStorage(userDefaults: UserDefaults(suiteName: suiteName)!)
    }

    /// A fresh subscription receives the CURRENT gate value without any nudge — the self-healing
    /// seed that makes a nudge dropped in the re-subscribe window harmless.
    @Test func aFreshSubscriptionSeedsItselfWithTheLiveGateValue() async {
        let first = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                isMigrationSyncBlocked: { true }
            )
        } operation: { () async -> Bool? in
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage())
            var iterator = manager.migrationSyncGateFeed().makeAsyncIterator()
            return await iterator.next()
        }

        #expect(first == true, "the install-time seed must deliver the live gate value, unprompted")
    }

    /// The ordinary push still works: after the seed, a `refreshMigrationSyncGate()` delivers the
    /// (possibly changed) value to the live subscription.
    @Test func aRefreshPushesTheCurrentValueToTheLiveSubscription() async {
        let blocked = LockIsolated(true)
        let values = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                isMigrationSyncBlocked: { blocked.value }
            )
        } operation: { () async -> [Bool] in
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage())
            var iterator = manager.migrationSyncGateFeed().makeAsyncIterator()
            let seed = await iterator.next()

            blocked.withValue { $0 = false }
            await manager.refreshMigrationSyncGate()
            let pushed = await iterator.next()

            return [seed, pushed].compactMap { $0 }
        }

        #expect(values == [true, false], "seed first, then the nudged value — got \(values)")
    }
}
