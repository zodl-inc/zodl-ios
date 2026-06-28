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
