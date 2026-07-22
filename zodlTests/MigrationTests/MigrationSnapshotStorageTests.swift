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

    // MARK: - MOB-1497 (R9-T6, finding 8): ensureOrCreate — atomic decide-and-write for the create
    // path. `MigrationManagerImpl.ensureOrCreateNetworkSnapshot`'s create path no longer serializes
    // through `transactionGuard` (see that method's doc) — the race-closing atomicity a concurrent
    // "check absent -> create -> write" needs now lives entirely in this method instead. These pin
    // its decision table directly, independent of the higher-level `MigrationManagerTests` coverage
    // that exercises it through `formNetworkSnapshot`/`migrationNetworkOptions`.

    @Test func ensureOrCreateWritesAndReturnsTheCandidateWhenNoSnapshotExists() throws {
        try withStorage("testEnsureOrCreateWritesAndReturnsTheCandidateWhenNoSnapshotExists") { storage in
            let accountUUID = Self.accountUUID(28)
            let candidate = Self.snapshot(syncHost: "na.zec.rocks")

            let result = storage.ensureOrCreate(candidate: candidate, reformIfProvisional: true, for: accountUUID)

            #expect(result == candidate)
            #expect(storage.snapshot(for: accountUUID) == candidate)
        }
    }

    /// A committed snapshot is never reformed, even when the caller asks for reform — mirrors
    /// `formNetworkSnapshotReturnsACommittedSnapshotUnchangedEvenWhenTheStoredChoiceDiffers` in
    /// `MigrationManagerTests`, pinned here directly at the storage layer too.
    @Test func ensureOrCreateKeepsAnExistingCommittedSnapshotEvenWhenReformIfProvisionalIsTrue() throws {
        try withStorage("testEnsureOrCreateKeepsAnExistingCommittedSnapshotEvenWhenReformIfProvisionalIsTrue") { storage in
            let accountUUID = Self.accountUUID(29)
            let existing = Self.snapshot(syncHost: "zec.rocks", committedAt: Date(timeIntervalSince1970: 1_000_000))
            storage.recordSnapshot(existing, for: accountUUID)
            let candidate = Self.snapshot(syncHost: "na.zec.rocks")

            let result = storage.ensureOrCreate(candidate: candidate, reformIfProvisional: true, for: accountUUID)

            #expect(result == existing)
            #expect(storage.snapshot(for: accountUUID) == existing)
        }
    }

    /// `formNetworkSnapshot`'s own reform rule: a still-provisional existing snapshot is discarded
    /// for the fresh candidate when the caller asks for reform.
    @Test func ensureOrCreateOverwritesAProvisionalSnapshotWithTheCandidateWhenReformIfProvisionalIsTrue() throws {
        try withStorage("testEnsureOrCreateOverwritesAProvisionalSnapshotWithTheCandidateWhenReformIfProvisionalIsTrue") { storage in
            let accountUUID = Self.accountUUID(30)
            let existing = Self.snapshot(syncHost: "zec.rocks")
            storage.recordSnapshot(existing, for: accountUUID)
            let candidate = Self.snapshot(syncHost: "na.zec.rocks")

            let result = storage.ensureOrCreate(candidate: candidate, reformIfProvisional: true, for: accountUUID)

            #expect(result == candidate)
            #expect(storage.snapshot(for: accountUUID) == candidate)
        }
    }

    /// `ensureNetworkSnapshot`'s safety-net rule: stays idempotent against a provisional existing
    /// snapshot too when the caller does not ask for reform.
    @Test func ensureOrCreateKeepsAnExistingProvisionalSnapshotWhenReformIfProvisionalIsFalse() throws {
        try withStorage("testEnsureOrCreateKeepsAnExistingProvisionalSnapshotWhenReformIfProvisionalIsFalse") { storage in
            let accountUUID = Self.accountUUID(31)
            let existing = Self.snapshot(syncHost: "zec.rocks")
            storage.recordSnapshot(existing, for: accountUUID)
            let candidate = Self.snapshot(syncHost: "na.zec.rocks")

            let result = storage.ensureOrCreate(candidate: candidate, reformIfProvisional: false, for: accountUUID)

            #expect(result == existing)
            #expect(storage.snapshot(for: accountUUID) == existing)
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

    // MARK: - MOB-1497 (R7-T3, R7-review fix Important-1): sanctioned ACTIVE-snapshot mutations
    // (R14/R16/R17) — committed if one exists, else the still-provisional one. Originally
    // committed-only; widened because the live Keystone note-split lane's broadcast (and therefore
    // its first R14/R16/R17 failure) happens against a snapshot that is STILL PROVISIONAL by design
    // — see `MigrationManagerImpl.routeBroadcastFailure`'s doc.

    @Test func overrideUseTorOnActiveSnapshotMutatesOnlyUseTorOnACommittedSnapshot() throws {
        try withStorage("testOverrideUseTorOnActiveSnapshotMutatesOnlyUseTorOnACommittedSnapshot") { storage in
            let accountUUID = Self.accountUUID(19)
            let committedAt = Date(timeIntervalSince1970: 1_000_000)
            let original = Self.snapshot(useTor: true, syncHost: "eu.zec.rocks", broadcastHost: "us.zec.stardust.rest", committedAt: committedAt)
            storage.recordSnapshot(original, for: accountUUID)

            storage.overrideUseTorOnActiveSnapshot(false, for: accountUUID)

            let updated = try #require(storage.snapshot(for: accountUUID))
            #expect(updated.useTor == false)
            #expect(updated.syncEndpoint == original.syncEndpoint)
            #expect(updated.syncProvider == original.syncProvider)
            #expect(updated.broadcastEndpoint == original.broadcastEndpoint)
            #expect(updated.broadcastProvider == original.broadcastProvider)
            #expect(updated.takenAt == original.takenAt)
            #expect(updated.committedAt == committedAt)
        }
    }

    /// R7-review fix (Important-1): RED against the pre-fix committed-only guard, which left
    /// `useTor` at `true` here — the note-split lane's R14 override must be able to act on a
    /// still-provisional snapshot too, since that lane's first broadcast happens before commit.
    @Test func overrideUseTorOnActiveSnapshotMutatesUseTorOnAProvisionalSnapshotToo() throws {
        try withStorage("testOverrideUseTorOnActiveSnapshotMutatesUseTorOnAProvisionalSnapshotToo") { storage in
            let accountUUID = Self.accountUUID(20)
            let original = Self.snapshot(useTor: true, syncHost: "eu.zec.rocks", broadcastHost: "us.zec.stardust.rest")
            storage.recordSnapshot(original, for: accountUUID)

            storage.overrideUseTorOnActiveSnapshot(false, for: accountUUID)

            let updated = try #require(storage.snapshot(for: accountUUID))
            #expect(updated.useTor == false)
            #expect(updated.committedAt == nil)
            // Every other field stays byte-for-byte untouched, same as the committed case.
            #expect(updated.syncEndpoint == original.syncEndpoint)
            #expect(updated.broadcastEndpoint == original.broadcastEndpoint)
        }
    }

    @Test func overrideUseTorOnActiveSnapshotIsANoOpWhenNoSnapshotIsPersisted() throws {
        try withStorage("testOverrideUseTorOnActiveSnapshotIsANoOpWhenNoSnapshotIsPersisted") { storage in
            let accountUUID = Self.accountUUID(21)

            storage.overrideUseTorOnActiveSnapshot(false, for: accountUUID)

            #expect(storage.snapshot(for: accountUUID) == nil)
        }
    }

    @Test func rotateBroadcastEndpointMutatesOnlyBroadcastEndpointOnACommittedSnapshot() throws {
        try withStorage("testRotateBroadcastEndpointMutatesOnlyBroadcastEndpointOnACommittedSnapshot") { storage in
            let accountUUID = Self.accountUUID(22)
            let committedAt = Date(timeIntervalSince1970: 1_000_000)
            let original = Self.snapshot(useTor: true, syncHost: "zec.rocks", broadcastHost: "us.zec.stardust.rest", committedAt: committedAt)
            storage.recordSnapshot(original, for: accountUUID)
            let rotated = MigrationNetworkSnapshot.Endpoint(host: "eu.zec.stardust.rest", port: 443, secure: true)

            storage.rotateBroadcastEndpoint(to: rotated, for: accountUUID)

            let updated = try #require(storage.snapshot(for: accountUUID))
            #expect(updated.broadcastEndpoint == rotated)
            // Provider unchanged — rotation is within-provider by construction (the caller only
            // ever offers a same-provider candidate).
            #expect(updated.broadcastProvider == original.broadcastProvider)
            #expect(updated.useTor == original.useTor)
            #expect(updated.syncEndpoint == original.syncEndpoint)
            #expect(updated.syncProvider == original.syncProvider)
            #expect(updated.takenAt == original.takenAt)
            #expect(updated.committedAt == committedAt)
        }
    }

    /// R7-review fix (Important-1): RED against the pre-fix committed-only guard, which left
    /// `broadcastEndpoint` untouched here — the R16 rotation must be able to act on a
    /// still-provisional snapshot too. See `overrideUseTorOnActiveSnapshotMutatesUseTorOnAProvisionalSnapshotToo`'s
    /// doc for the shared rationale.
    @Test func rotateBroadcastEndpointMutatesABroadcastEndpointOnAProvisionalSnapshotToo() throws {
        try withStorage("testRotateBroadcastEndpointMutatesABroadcastEndpointOnAProvisionalSnapshotToo") { storage in
            let accountUUID = Self.accountUUID(23)
            let original = Self.snapshot(broadcastHost: "us.zec.stardust.rest")
            storage.recordSnapshot(original, for: accountUUID)
            let rotated = MigrationNetworkSnapshot.Endpoint(host: "eu.zec.stardust.rest", port: 443, secure: true)

            storage.rotateBroadcastEndpoint(to: rotated, for: accountUUID)

            let updated = try #require(storage.snapshot(for: accountUUID))
            #expect(updated.broadcastEndpoint == rotated)
            #expect(updated.committedAt == nil)
            #expect(updated.broadcastProvider == original.broadcastProvider)
        }
    }

    @Test func rotateBroadcastEndpointIsANoOpWhenNoSnapshotIsPersisted() throws {
        try withStorage("testRotateBroadcastEndpointIsANoOpWhenNoSnapshotIsPersisted") { storage in
            let accountUUID = Self.accountUUID(24)
            let rotated = MigrationNetworkSnapshot.Endpoint(host: "eu.zec.stardust.rest", port: 443, secure: true)

            storage.rotateBroadcastEndpoint(to: rotated, for: accountUUID)

            #expect(storage.snapshot(for: accountUUID) == nil)
        }
    }

    @Test func overrideBroadcastEndpointToSyncServerOnActiveSnapshotSetsBroadcastToSyncOnACommittedSnapshot() throws {
        try withStorage("testOverrideBroadcastEndpointToSyncServerOnActiveSnapshotSetsBroadcastToSyncOnACommittedSnapshot") { storage in
            let accountUUID = Self.accountUUID(25)
            let committedAt = Date(timeIntervalSince1970: 1_000_000)
            let original = Self.snapshot(useTor: true, syncHost: "na.zec.rocks", broadcastHost: "us.zec.stardust.rest", committedAt: committedAt)
            storage.recordSnapshot(original, for: accountUUID)

            storage.overrideBroadcastEndpointToSyncServerOnActiveSnapshot(for: accountUUID)

            let updated = try #require(storage.snapshot(for: accountUUID))
            #expect(updated.broadcastEndpoint == original.syncEndpoint)
            #expect(updated.broadcastProvider == original.syncProvider)
            #expect(updated.useTor == original.useTor)
            #expect(updated.syncEndpoint == original.syncEndpoint)
            #expect(updated.syncProvider == original.syncProvider)
            #expect(updated.takenAt == original.takenAt)
            #expect(updated.committedAt == committedAt)
        }
    }

    /// R7-review fix (Important-1): RED against the pre-fix committed-only guard, which left
    /// `broadcastEndpoint` untouched here — the R17 sync-server fallback must be able to act on a
    /// still-provisional snapshot too. See `overrideUseTorOnActiveSnapshotMutatesUseTorOnAProvisionalSnapshotToo`'s
    /// doc for the shared rationale.
    @Test func overrideBroadcastEndpointToSyncServerOnActiveSnapshotSetsBroadcastToSyncOnAProvisionalSnapshotToo() throws {
        try withStorage("testOverrideBroadcastEndpointToSyncServerOnActiveSnapshotSetsBroadcastToSyncOnAProvisionalSnapshotToo") { storage in
            let accountUUID = Self.accountUUID(26)
            let original = Self.snapshot(syncHost: "na.zec.rocks", broadcastHost: "us.zec.stardust.rest")
            storage.recordSnapshot(original, for: accountUUID)

            storage.overrideBroadcastEndpointToSyncServerOnActiveSnapshot(for: accountUUID)

            let updated = try #require(storage.snapshot(for: accountUUID))
            #expect(updated.broadcastEndpoint == original.syncEndpoint)
            #expect(updated.broadcastProvider == original.syncProvider)
            #expect(updated.committedAt == nil)
        }
    }

    @Test func overrideBroadcastEndpointToSyncServerOnActiveSnapshotIsANoOpWhenNoSnapshotIsPersisted() throws {
        try withStorage("testOverrideBroadcastEndpointToSyncServerOnActiveSnapshotIsANoOpWhenNoSnapshotIsPersisted") { storage in
            let accountUUID = Self.accountUUID(27)

            storage.overrideBroadcastEndpointToSyncServerOnActiveSnapshot(for: accountUUID)

            #expect(storage.snapshot(for: accountUUID) == nil)
        }
    }
}
