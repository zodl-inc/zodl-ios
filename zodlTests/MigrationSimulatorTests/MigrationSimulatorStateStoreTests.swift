//
//  MigrationSimulatorStateStoreTests.swift
//  zodlTests
//
//  Covers `MigrationSimulatorStateStore` (MOB-1480): the ephemeral (in-memory) store used by
//  engine tests, and the live (file-backed) store's round-trip + reseed-on-corruption/version-
//  mismatch behavior. No shared/global state (each test uses its own temp file or an isolated
//  in-memory store) -> no `.serialized`.
//

import Testing
import Foundation
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationSimulatorStateStoreTests {
    // MARK: - Ephemeral

    @Test func ephemeralStoreStartsWithSeededDefault() {
        let store = MigrationSimulatorStateStore.ephemeral()

        #expect(store.load() == SimulatorSnapshot.seeded())
    }

    @Test func ephemeralStoreRoundTripsSaveAndLoad() {
        let store = MigrationSimulatorStateStore.ephemeral()
        var snapshot = SimulatorSnapshot.seeded()
        snapshot.orchardBalance = Zatoshi(42)
        snapshot.state = MigrationState.readyToPropose

        store.save(snapshot)

        #expect(store.load() == snapshot)
    }

    @Test func ephemeralStoreClearResetsToSeededDefault() {
        let store = MigrationSimulatorStateStore.ephemeral()
        var snapshot = SimulatorSnapshot.seeded()
        snapshot.orchardBalance = Zatoshi(999)
        store.save(snapshot)

        store.clear()

        #expect(store.load() == SimulatorSnapshot.seeded())
    }

    // MARK: - Live (file-backed)

    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("migration_simulator_test_\(UUID().uuidString).json")
    }

    @Test func liveStoreReturnsSeededDefaultWhenFileMissing() {
        let url = makeTempFileURL()
        let store = MigrationSimulatorStateStore.live(fileURL: url)

        #expect(store.load() == SimulatorSnapshot.seeded())

        try? FileManager.default.removeItem(at: url)
    }

    @Test func liveStoreRoundTripsSaveAndLoad() {
        let url = makeTempFileURL()
        let store = MigrationSimulatorStateStore.live(fileURL: url)
        var snapshot = SimulatorSnapshot.seeded()
        snapshot.orchardBalance = Zatoshi(123_456)
        snapshot.signedBatchCount = 3

        store.save(snapshot)

        #expect(store.load() == snapshot)

        try? FileManager.default.removeItem(at: url)
    }

    @Test func liveStoreReseedsAndPersistsOnDecodeFailure() {
        let url = makeTempFileURL()
        try? Data("not valid json".utf8).write(to: url)

        let store = MigrationSimulatorStateStore.live(fileURL: url)
        let loaded = store.load()

        #expect(loaded == SimulatorSnapshot.seeded())

        // The reseed must have been persisted: a fresh store instance over the same file also
        // reads the seeded default (not a fresh "missing file" seed that happens to look the
        // same) — verified via the file now containing valid, decodable JSON.
        let data = try? Data(contentsOf: url)
        let decoded = data.flatMap { try? JSONDecoder().decode(SimulatorSnapshot.self, from: $0) }
        #expect(decoded == SimulatorSnapshot.seeded())

        try? FileManager.default.removeItem(at: url)
    }

    @Test func liveStoreReseedsOnSchemaVersionMismatch() throws {
        let url = makeTempFileURL()
        var stale = SimulatorSnapshot.seeded()
        stale.schemaVersion = SimulatorSnapshot.currentSchemaVersion + 1
        stale.orchardBalance = Zatoshi(777)
        let data = try JSONEncoder().encode(stale)
        try data.write(to: url)

        let store = MigrationSimulatorStateStore.live(fileURL: url)

        #expect(store.load() == SimulatorSnapshot.seeded())

        try? FileManager.default.removeItem(at: url)
    }

    @Test func liveStoreClearRemovesFile() {
        let url = makeTempFileURL()
        let store = MigrationSimulatorStateStore.live(fileURL: url)
        store.save(SimulatorSnapshot.seeded())
        #expect(FileManager.default.fileExists(atPath: url.path))

        store.clear()

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
