//
//  MigrationStateStoreTests.swift
//  zodlTests
//
//  Persistence round-trip for the migration snapshot.
//

import Testing
import Foundation
@testable import zodl_internal
@preconcurrency import ZcashLightClientKit

@Suite(.serialized)
struct MigrationStateStoreTests {
    @Test func ephemeralRoundTrips() {
        let store = MigrationStateStore.ephemeral()
        var snapshot = MigrationSnapshot.seededDefault
        snapshot.currentHeight = 123
        snapshot.orchard = Zatoshi(42)

        store.save(snapshot)
        #expect(store.load() == snapshot)
    }

    @Test func liveRoundTripsAndClearsToDefault() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mig-test-\(UUID().uuidString).json")
        let store = MigrationStateStore.live(fileURL: url)

        var snapshot = MigrationSnapshot.seededDefault
        snapshot.state = .complete
        snapshot.transfers = [
            StoredTransfer(
                proposal: TransferProposal(
                    id: "t1",
                    amount: Zatoshi(5),
                    anchorHeight: 1,
                    nextExecutableAfterHeight: 2,
                    expiryHeight: 3
                ),
                status: .sent(txId: "abc")
            )
        ]

        store.save(snapshot)
        #expect(store.load() == snapshot)

        store.clear()
        #expect(store.load() == MigrationSnapshot.seededDefault)
    }
}

@Suite(.serialized)
struct MigrationRunLogStoreTests {
    @Test func ephemeralAppendsNewestFirstAndClears() {
        let store = MigrationRunLogStore.ephemeral()
        #expect(store.load().isEmpty)

        store.append(MigrationBackgroundRun(timestamp: Date(timeIntervalSince1970: 1), outcome: .nothingPending))
        store.append(MigrationBackgroundRun(timestamp: Date(timeIntervalSince1970: 2), outcome: .sent(txId: "tx")))

        let log = store.load()
        #expect(log.count == 2)
        // Newest first.
        #expect(log.first?.timestamp == Date(timeIntervalSince1970: 2))
        #expect(log.first?.outcome == .sent(txId: "tx"))

        store.clear()
        #expect(store.load().isEmpty)
    }

    @Test func capsAtCapacity() {
        let store = MigrationRunLogStore.ephemeral()
        for i in 0..<(MigrationRunLogStore.capacity + 25) {
            store.append(MigrationBackgroundRun(timestamp: Date(timeIntervalSince1970: Double(i)), outcome: .nothingPending))
        }
        #expect(store.load().count == MigrationRunLogStore.capacity)
    }

    @Test func liveRoundTripsAndClears() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mig-runlog-\(UUID().uuidString).json")
        let store = MigrationRunLogStore.live(fileURL: url)
        #expect(store.load().isEmpty)

        store.append(MigrationBackgroundRun(timestamp: Date(timeIntervalSince1970: 10), outcome: .networkError))
        #expect(store.load().count == 1)
        #expect(store.load().first?.outcome == .networkError)

        store.clear()
        #expect(store.load().isEmpty)
    }
}
