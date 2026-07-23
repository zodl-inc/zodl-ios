//
//  MigrationKeystoneBatchChunkingTests.swift
//  zodlTests
//
//  Covers the pure Keystone batch chunker (MOB-1513 E3):
//  `MigrationCoordFlow.chunkKeystoneBatch` slices a proposed PCZT batch into QR signing rounds of at
//  most `keystoneMaxPCZTsPerRound` (35, Android parity after a real device OOM at 50), with the
//  preparation (note-split) PCZTs occupying round 0 first. No shared/global state -> no `.serialized`.
//

import Testing
import Foundation
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationKeystoneBatchChunkingTests {
    private func transfer(_ id: String) -> MigrationUnsignedTransferPczt {
        MigrationUnsignedTransferPczt(id: id, pczt: Data([UInt8(truncatingIfNeeded: id.hashValue)]))
    }

    private func transfers(_ count: Int) -> [MigrationUnsignedTransferPczt] {
        (0..<count).map { transfer("t\($0)") }
    }

    private func prep(_ index: Int) -> MigrationUnsignedTransferPczt {
        transfer(MigrationCoordFlow.keystoneNoteSplitSentinelPrefix + "p\(index)")
    }

    @Test func capIs35() {
        #expect(MigrationCoordFlow.keystoneMaxPCZTsPerRound == 35)
    }

    /// Boundary table: 0 / 1 / 34 / 35 / 36 / 70 / 71 items.
    @Test func chunkingBoundaries() {
        #expect(MigrationCoordFlow.chunkKeystoneBatch(transfers(0)).map(\.count) == [])
        #expect(MigrationCoordFlow.chunkKeystoneBatch(transfers(1)).map(\.count) == [1])
        #expect(MigrationCoordFlow.chunkKeystoneBatch(transfers(34)).map(\.count) == [34])
        #expect(MigrationCoordFlow.chunkKeystoneBatch(transfers(35)).map(\.count) == [35])
        #expect(MigrationCoordFlow.chunkKeystoneBatch(transfers(36)).map(\.count) == [35, 1])
        #expect(MigrationCoordFlow.chunkKeystoneBatch(transfers(70)).map(\.count) == [35, 35])
        #expect(MigrationCoordFlow.chunkKeystoneBatch(transfers(71)).map(\.count) == [35, 35, 1])
    }

    @Test func chunkingCoversEveryItemInOrder() {
        let batch = transfers(71)
        let rounds = MigrationCoordFlow.chunkKeystoneBatch(batch)
        #expect(rounds.flatMap { $0 } == batch)
    }

    /// The split-first-in-round-0 invariant: preparation PCZTs fill round 0 first, transfers after,
    /// further rounds hold the remaining transfers.
    @Test func prepsOccupyRoundZeroFirst() {
        let preps = [prep(0), prep(1)]
        let batch = preps + transfers(40)
        let rounds = MigrationCoordFlow.chunkKeystoneBatch(batch)

        #expect(rounds.map(\.count) == [35, 7])
        #expect(rounds[0][0].id == MigrationCoordFlow.keystoneNoteSplitSentinelPrefix + "p0")
        #expect(rounds[0][1].id == MigrationCoordFlow.keystoneNoteSplitSentinelPrefix + "p1")
        // Every prep is in round 0, none leak into a later round.
        let round0Ids = Set(rounds[0].map(\.id))
        #expect(preps.allSatisfy { round0Ids.contains($0.id) })
        #expect(rounds.dropFirst().allSatisfy { round in
            round.allSatisfy { !$0.id.hasPrefix(MigrationCoordFlow.keystoneNoteSplitSentinelPrefix) }
        })
    }

    @Test func batchWithoutPrepsChunksTransfersInOrder() {
        let batch = transfers(36)
        let rounds = MigrationCoordFlow.chunkKeystoneBatch(batch)

        #expect(rounds.map(\.count) == [35, 1])
        #expect(rounds.flatMap { $0 } == batch)
    }

    @Test func singleRoundBatchIsExactlyOneRound() {
        // ≤ 35 stays a single round — the path that must remain byte-identical to the pre-E3 ceremony.
        let batch = transfers(35)
        let rounds = MigrationCoordFlow.chunkKeystoneBatch(batch)
        #expect(rounds.count == 1)
        #expect(rounds[0] == batch)
    }
}
