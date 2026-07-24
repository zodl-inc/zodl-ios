//
//  KeystoneBatchChunking.swift
//  zodl
//
//  MOB-1513 (R9): the device-safety cap on how many PCZTs one Keystone batch-signing QR round trip
//  may cover. A Keystone device has to hold and process an entire round's batch before it can sign
//  any of it, so an unbounded batch risks exhausting the device; this cap keeps every round inside a
//  budget the hardware has actually been exercised against. `MigrationCoordFlowCoordinator`'s
//  ceremony loop is what turns the cap into behavior: a migration batch that exceeds it is split
//  across multiple QR round trips instead of sent as one oversized round.
//
//  Set to 32 = the wallet-team budget of 96 Orchard/Ironwood actions total per signing round
//  (decision by Michal, 2026-07-24, superseding both this repo's earlier ≤35-item cap — the
//  pre-real-SDK `chunkKeystoneBatch` chunker MOB-1513 removed; see `MigrationCoordFlowCoordinator`'s
//  header — and Android's 40-item cap) ÷ ~3 actions per transfer transaction.
//
//  Mechanism parity with Android's production `KeystoneBatchChunking.kt`: the chunker itself works
//  off a flat runtime item count, exactly like this file — the action budget above is only the
//  OFFLINE arithmetic that derived the 32 constant, never recomputed at runtime. Android observed a
//  real Keystone device OOM at a 50-item batch, and validated a 120-action batch on-device; every
//  PCZT here costs one slot regardless of its real action count, an approximation both platforms
//  accept.
//
//  Preparation (note-split) PCZTs already lead the flat PCZT list at the call site
//  (`MigrationCommitPipeline.proposeKeystoneBatch`), so plain in-order slicing keeps them in round 0
//  without any special-casing here.
//

/// The device-safety cap on how many PCZTs one Keystone batch-signing QR round trip may cover, and
/// the pure arithmetic that slices a flat, already-ordered PCZT list into rounds against that cap.
/// See this file's header for where 32 comes from and how it mirrors Android's
/// `KeystoneBatchChunking.kt`.
enum KeystoneBatchChunking {
    /// The device-safety cap: at most this many PCZTs travel in one Keystone batch-signing QR round
    /// trip. See this file's header for the derivation (96 actions/round budget ÷ ~3 actions/transfer).
    static let maxItemsPerRound = 32

    /// How many rounds it takes to cover `itemCount` PCZTs at `maxItemsPerRound` items per round:
    /// `0` for an empty batch, otherwise `ceil(itemCount / maxItemsPerRound)` computed in integer
    /// arithmetic.
    static func totalRounds(itemCount: Int, maxItemsPerRound: Int = KeystoneBatchChunking.maxItemsPerRound) -> Int {
        precondition(maxItemsPerRound > 0, "KeystoneBatchChunking.totalRounds requires a positive maxItemsPerRound")
        precondition(itemCount >= 0, "KeystoneBatchChunking.totalRounds requires a non-negative itemCount")

        guard itemCount > 0 else { return 0 }
        return (itemCount + maxItemsPerRound - 1) / maxItemsPerRound
    }

    /// The flat, in-order slice of `0..<itemCount` that round `roundIndex` (0-based) covers: `start`
    /// is `roundIndex * maxItemsPerRound` clamped to `itemCount`, `end` is `start + maxItemsPerRound`
    /// clamped to `itemCount`. A `roundIndex` at or past `totalRounds(itemCount:maxItemsPerRound:)`
    /// yields the empty range `itemCount..<itemCount`.
    ///
    /// Concatenating `roundSlice(roundIndex:itemCount:maxItemsPerRound:)` for every `roundIndex` in
    /// `0..<totalRounds(itemCount:maxItemsPerRound:)` exactly partitions `0..<itemCount` in order: no
    /// gaps, no overlaps, and every non-final round has exactly `maxItemsPerRound` items.
    static func roundSlice(
        roundIndex: Int,
        itemCount: Int,
        maxItemsPerRound: Int = KeystoneBatchChunking.maxItemsPerRound
    ) -> Range<Int> {
        precondition(roundIndex >= 0, "KeystoneBatchChunking.roundSlice requires a non-negative roundIndex")
        precondition(maxItemsPerRound > 0, "KeystoneBatchChunking.roundSlice requires a positive maxItemsPerRound")
        precondition(itemCount >= 0, "KeystoneBatchChunking.roundSlice requires a non-negative itemCount")

        let start = min(roundIndex * maxItemsPerRound, itemCount)
        let end = min(start + maxItemsPerRound, itemCount)
        return start..<end
    }
}
