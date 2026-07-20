//
//  MigrationSnapshotStorageTests.swift
//  zodlTests
//
//  Covers `MigrationSnapshotStorage` (Dependencies/MigrationManager/MigrationManagerLiveKey.swift) —
//  MOB-1496 W4: per-account persistence for the atomic migration network snapshot. `.serialized`:
//  every storage test shares the `UserDefaults` global (same reasoning as `MigrationScheduleStorageTests`).
//

import Testing
import Foundation
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized)
struct MigrationSnapshotStorageTests {
    private static func accountUUID(_ byte: UInt8) -> AccountUUID {
        AccountUUID(id: [UInt8](repeating: byte, count: 16))
    }

    private static func snapshot(
        useTor: Bool = false,
        syncHost: String = "zec.rocks",
        broadcastHost: String = "us.zec.stardust.rest",
        takenAt: Date = Date(timeIntervalSince1970: 1_000_000),
        committedAt: Date? = nil
    ) -> MigrationNetworkSnapshot {
        MigrationNetworkSnapshot(
            useTor: useTor,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: syncHost, port: 443, secure: true),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: broadcastHost, port: 443, secure: true),
            takenAt: takenAt,
            committedAt: committedAt
        )
    }

    private func withStorage(
        _ name: String,
        _ body: (MigrationSnapshotStorage) throws -> Void
    ) throws {
        let userDefaults = try #require(UserDefaults(suiteName: name), "MigrationSnapshotStorage: UserDefaults failed to initialize")
        defer { userDefaults.removePersistentDomain(forName: name) }
        try body(MigrationSnapshotStorage(userDefaults: userDefaults))
    }

    // MARK: - Round-trip: record -> read

    @Test func snapshotIsNilBeforeAnyRecord() throws {
        try withStorage("testSnapshotIsNilBeforeAnyRecord") { storage in
            #expect(storage.snapshot(for: Self.accountUUID(1)) == nil)
        }
    }

    @Test func recordSnapshotThenReadReturnsItWithEveryFieldIntact() throws {
        try withStorage("testRecordSnapshotThenReadReturnsItWithEveryFieldIntact") { storage in
            let accountUUID = Self.accountUUID(2)
            let recorded = Self.snapshot(useTor: true, syncHost: "eu.zec.rocks", broadcastHost: "eu.zec.stardust.rest")

            storage.recordSnapshot(recorded, for: accountUUID)

            let payload = try #require(storage.snapshot(for: accountUUID))
            #expect(payload == recorded)
            #expect(payload.useTor == true)
            #expect(payload.syncEndpoint.host == "eu.zec.rocks")
            #expect(payload.syncProvider == ServerProvider.zecRocks)
            #expect(payload.broadcastEndpoint.host == "eu.zec.stardust.rest")
            #expect(payload.broadcastProvider == ServerProvider.stardust)
            #expect(payload.takenAt == recorded.takenAt)
        }
    }

    @Test func recordSnapshotOverwritesAnExistingOne() throws {
        try withStorage("testRecordSnapshotOverwritesAnExistingOne") { storage in
            let accountUUID = Self.accountUUID(3)
            storage.recordSnapshot(Self.snapshot(syncHost: "zec.rocks"), for: accountUUID)

            let replacement = Self.snapshot(syncHost: "na.zec.rocks", takenAt: Date(timeIntervalSince1970: 2_000_000))
            storage.recordSnapshot(replacement, for: accountUUID)

            let payload = try #require(storage.snapshot(for: accountUUID))
            #expect(payload == replacement)
            #expect(payload.syncEndpoint.host == "na.zec.rocks")
        }
    }

    // MARK: - Round-trip: clear + per-account isolation

    @Test func clearRemovesTheSnapshot() throws {
        try withStorage("testClearRemovesTheSnapshot") { storage in
            let accountUUID = Self.accountUUID(4)
            storage.recordSnapshot(Self.snapshot(), for: accountUUID)
            #expect(storage.snapshot(for: accountUUID) != nil)

            storage.clear(for: accountUUID)

            #expect(storage.snapshot(for: accountUUID) == nil)
        }
    }

    @Test func clearingOneAccountLeavesAnotherAccountsSnapshotIntact() throws {
        try withStorage("testClearingOneAccountLeavesAnotherAccountsSnapshotIntact") { storage in
            let accountA = Self.accountUUID(5)
            let accountB = Self.accountUUID(6)
            storage.recordSnapshot(Self.snapshot(syncHost: "zec.rocks"), for: accountA)
            storage.recordSnapshot(Self.snapshot(syncHost: "na.zec.rocks"), for: accountB)

            storage.clear(for: accountA)

            #expect(storage.snapshot(for: accountA) == nil)
            #expect(storage.snapshot(for: accountB) != nil)
        }
    }

    @Test func perAccountSnapshotsAreIsolated() throws {
        try withStorage("testPerAccountSnapshotsAreIsolated") { storage in
            let accountA = Self.accountUUID(7)
            let accountB = Self.accountUUID(8)

            storage.recordSnapshot(Self.snapshot(), for: accountA)

            #expect(storage.snapshot(for: accountA) != nil)
            #expect(storage.snapshot(for: accountB) == nil)
        }
    }

    @Test func snapshotPersistsAcrossStorageInstancesUsingTheSameSuite() throws {
        // NOT `withStorage(_:_:)` here — its `defer` would wipe the suite the moment the first
        // closure returns, before a second instance ever gets to read it. Matches
        // `MigrationScheduleStorageTests`'s `payloadPersistsAcrossStorageInstancesUsingTheSameSuite`.
        let suiteName = "testSnapshotPersistsAcrossStorageInstancesUsingTheSameSuite"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let accountUUID = Self.accountUUID(9)
        let recorded = Self.snapshot(syncHost: "sa.zec.rocks")

        let firstStorage = MigrationSnapshotStorage(userDefaults: userDefaults)
        firstStorage.recordSnapshot(recorded, for: accountUUID)

        // A fresh instance over the same UserDefaults suite (simulating relaunch) must observe the
        // persisted snapshot, not start empty.
        let secondStorage = MigrationSnapshotStorage(userDefaults: userDefaults)
        #expect(secondStorage.snapshot(for: accountUUID)?.syncEndpoint.host == "sa.zec.rocks")
    }

    // MARK: - MOB-1497: provisional-until-commit lifecycle (committedAt / markCommitted /
    // clearIfCommitted / clearIfProvisional)

    @Test func recordedSnapshotDefaultsToProvisionalWhenCommittedAtOmitted() throws {
        try withStorage("testRecordedSnapshotDefaultsToProvisionalWhenCommittedAtOmitted") { storage in
            let accountUUID = Self.accountUUID(10)
            storage.recordSnapshot(Self.snapshot(), for: accountUUID)

            #expect(storage.snapshot(for: accountUUID)?.committedAt == nil)
        }
    }

    @Test func markCommittedStampsCommittedAtOnAProvisionalSnapshot() throws {
        try withStorage("testMarkCommittedStampsCommittedAtOnAProvisionalSnapshot") { storage in
            let accountUUID = Self.accountUUID(11)
            storage.recordSnapshot(Self.snapshot(), for: accountUUID)
            let now = Date(timeIntervalSince1970: 5_000_000)

            storage.markCommitted(for: accountUUID, now: now)

            #expect(storage.snapshot(for: accountUUID)?.committedAt == now)
        }
    }

    @Test func markCommittedIsANoOpWhenNoSnapshotIsPersisted() throws {
        try withStorage("testMarkCommittedIsANoOpWhenNoSnapshotIsPersisted") { storage in
            let accountUUID = Self.accountUUID(12)

            storage.markCommitted(for: accountUUID, now: Date())

            #expect(storage.snapshot(for: accountUUID) == nil)
        }
    }

    /// Idempotent: `committedAt` only ever moves nil -> a date, never back — a second stamp must not
    /// overwrite the FIRST commit's timestamp with a later one.
    @Test func markCommittedDoesNotOverwriteAnAlreadyCommittedTimestamp() throws {
        try withStorage("testMarkCommittedDoesNotOverwriteAnAlreadyCommittedTimestamp") { storage in
            let accountUUID = Self.accountUUID(13)
            storage.recordSnapshot(Self.snapshot(), for: accountUUID)
            let firstCommit = Date(timeIntervalSince1970: 1_000_000)
            let secondCommit = Date(timeIntervalSince1970: 2_000_000)

            storage.markCommitted(for: accountUUID, now: firstCommit)
            storage.markCommitted(for: accountUUID, now: secondCommit)

            #expect(storage.snapshot(for: accountUUID)?.committedAt == firstCommit)
        }
    }

    @Test func clearIfCommittedRemovesACommittedSnapshot() throws {
        try withStorage("testClearIfCommittedRemovesACommittedSnapshot") { storage in
            let accountUUID = Self.accountUUID(14)
            storage.recordSnapshot(Self.snapshot(committedAt: Date(timeIntervalSince1970: 1_000_000)), for: accountUUID)

            storage.clearIfCommitted(for: accountUUID)

            #expect(storage.snapshot(for: accountUUID) == nil)
        }
    }

    @Test func clearIfCommittedLeavesAProvisionalSnapshotIntact() throws {
        try withStorage("testClearIfCommittedLeavesAProvisionalSnapshotIntact") { storage in
            let accountUUID = Self.accountUUID(15)
            storage.recordSnapshot(Self.snapshot(), for: accountUUID)

            storage.clearIfCommitted(for: accountUUID)

            #expect(storage.snapshot(for: accountUUID) != nil)
        }
    }

    @Test func clearIfProvisionalRemovesAProvisionalSnapshot() throws {
        try withStorage("testClearIfProvisionalRemovesAProvisionalSnapshot") { storage in
            let accountUUID = Self.accountUUID(16)
            storage.recordSnapshot(Self.snapshot(), for: accountUUID)

            storage.clearIfProvisional(for: accountUUID)

            #expect(storage.snapshot(for: accountUUID) == nil)
        }
    }

    @Test func clearIfProvisionalLeavesACommittedSnapshotIntact() throws {
        try withStorage("testClearIfProvisionalLeavesACommittedSnapshotIntact") { storage in
            let accountUUID = Self.accountUUID(17)
            storage.recordSnapshot(Self.snapshot(committedAt: Date(timeIntervalSince1970: 1_000_000)), for: accountUUID)

            storage.clearIfProvisional(for: accountUUID)

            #expect(storage.snapshot(for: accountUUID) != nil)
        }
    }

    @Test func clearIfProvisionalIsANoOpWhenNoSnapshotIsPersisted() throws {
        try withStorage("testClearIfProvisionalIsANoOpWhenNoSnapshotIsPersisted") { storage in
            let accountUUID = Self.accountUUID(18)

            storage.clearIfProvisional(for: accountUUID)

            #expect(storage.snapshot(for: accountUUID) == nil)
        }
    }
}
