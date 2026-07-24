//
//  KeystoneBatchChunkingTests.swift
//  zodlTests
//
//  MOB-1513 (R9): covers the Keystone batch-signing round chunker
//  (Features/Migration/MigrationKeystoneSign/KeystoneBatchChunking.swift) — the device-safety cap
//  restored at 32 items/round (96-action wallet-team budget ÷ ~3 actions/transfer; see that file's
//  header for the full derivation and the Android parity it mirrors). Pure arithmetic, no mocks: the
//  constant pin, the total-rounds boundary math, the round-slice boundaries (including a single
//  partial round and an out-of-range round index), a custom `maxItemsPerRound`, and the partition
//  invariant tying them all together. No shared/global state -> no `.serialized`.
//

import Testing
@testable import zodl_internal

@Suite struct KeystoneBatchChunkingTests {
    // MARK: - maxItemsPerRound: pin the device-safety constant

    @Test func maxItemsPerRoundIsThirtyTwo() {
        #expect(KeystoneBatchChunking.maxItemsPerRound == 32)
    }

    // MARK: - totalRounds: ceil(itemCount / maxItemsPerRound) boundaries

    @Test func totalRoundsForZeroItemsIsZero() {
        #expect(KeystoneBatchChunking.totalRounds(itemCount: 0) == 0)
    }

    @Test func totalRoundsBoundariesAtDefaultCap() {
        #expect(KeystoneBatchChunking.totalRounds(itemCount: 1) == 1)
        #expect(KeystoneBatchChunking.totalRounds(itemCount: 32) == 1)
        #expect(KeystoneBatchChunking.totalRounds(itemCount: 33) == 2)
        #expect(KeystoneBatchChunking.totalRounds(itemCount: 64) == 2)
        #expect(KeystoneBatchChunking.totalRounds(itemCount: 65) == 3)
    }

    // MARK: - roundSlice: boundaries, a single partial round, and an out-of-range round index

    @Test func roundSliceBoundariesAtItemCountThirtyThree() {
        #expect(KeystoneBatchChunking.roundSlice(roundIndex: 0, itemCount: 33) == 0..<32)
        #expect(KeystoneBatchChunking.roundSlice(roundIndex: 1, itemCount: 33) == 32..<33)
    }

    @Test func roundSliceForASinglePartialRound() {
        #expect(KeystoneBatchChunking.roundSlice(roundIndex: 0, itemCount: 5) == 0..<5)
    }

    @Test func roundSliceOutOfRangeRoundIndexIsEmpty() {
        #expect(KeystoneBatchChunking.roundSlice(roundIndex: 3, itemCount: 5) == 5..<5)
    }

    // MARK: - Custom maxItemsPerRound

    @Test func customMaxItemsPerRoundIsRespected() {
        #expect(KeystoneBatchChunking.totalRounds(itemCount: 10, maxItemsPerRound: 4) == 3)
        #expect(KeystoneBatchChunking.roundSlice(roundIndex: 0, itemCount: 10, maxItemsPerRound: 4) == 0..<4)
        #expect(KeystoneBatchChunking.roundSlice(roundIndex: 1, itemCount: 10, maxItemsPerRound: 4) == 4..<8)
        #expect(KeystoneBatchChunking.roundSlice(roundIndex: 2, itemCount: 10, maxItemsPerRound: 4) == 8..<10)
    }

    // MARK: - Partition invariant: concatenated round slices exactly cover 0..<itemCount

    /// For every `itemCount`/`maxItemsPerRound` pair, concatenating `roundSlice` for every round in
    /// `0..<totalRounds` exactly partitions `0..<itemCount`: no gaps, no overlaps, in order, every
    /// non-final round has exactly `maxItemsPerRound` items, and the final round carries the
    /// remainder.
    @Test(arguments: [
        (itemCount: 0, maxItemsPerRound: KeystoneBatchChunking.maxItemsPerRound),
        (itemCount: 1, maxItemsPerRound: KeystoneBatchChunking.maxItemsPerRound),
        (itemCount: 31, maxItemsPerRound: KeystoneBatchChunking.maxItemsPerRound),
        (itemCount: 32, maxItemsPerRound: KeystoneBatchChunking.maxItemsPerRound),
        (itemCount: 33, maxItemsPerRound: KeystoneBatchChunking.maxItemsPerRound),
        (itemCount: 63, maxItemsPerRound: KeystoneBatchChunking.maxItemsPerRound),
        (itemCount: 64, maxItemsPerRound: KeystoneBatchChunking.maxItemsPerRound),
        (itemCount: 65, maxItemsPerRound: KeystoneBatchChunking.maxItemsPerRound),
        (itemCount: 100, maxItemsPerRound: KeystoneBatchChunking.maxItemsPerRound),
        (itemCount: 10, maxItemsPerRound: 3)
    ])
    func roundSlicesExactlyPartitionTheFullRange(itemCount: Int, maxItemsPerRound: Int) {
        let totalRounds = KeystoneBatchChunking.totalRounds(itemCount: itemCount, maxItemsPerRound: maxItemsPerRound)
        var covered: [Int] = []

        for roundIndex in 0..<totalRounds {
            let slice = KeystoneBatchChunking.roundSlice(
                roundIndex: roundIndex,
                itemCount: itemCount,
                maxItemsPerRound: maxItemsPerRound
            )
            let isFinalRound = roundIndex == totalRounds - 1

            if isFinalRound {
                #expect(slice.count > 0)
                #expect(slice.count <= maxItemsPerRound)
            } else {
                #expect(slice.count == maxItemsPerRound)
            }

            covered.append(contentsOf: slice)
        }

        #expect(covered == Array(0..<itemCount))
    }
}
