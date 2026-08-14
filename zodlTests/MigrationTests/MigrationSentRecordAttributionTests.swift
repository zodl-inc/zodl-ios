//
//  MigrationSentRecordAttributionTests.swift
//  zodlTests
//
//  MOB-1466 (M2, SDK delegation): a landed broadcast's `SentRecord` is keyed to the transfer the
//  delivery lane ACTUALLY served, not to "the first row in the persisted array with no record yet".
//
//  THE BUG CLASS. The persisted schedule array carries crossing order; the engine delivers in
//  schedule-SLOT order (and rebuilds/withholds can reorder delivery further). The old positional
//  guess was only ever right while those orders coincided — with the SDK now delegating selection
//  to the engine's height-ordered reads, a success could be recorded against the WRONG transfer:
//  wrong row green, wrong amount shown, txid keyed to the wrong id for R11's wallet-confirmation
//  match. `MigrationScheduleStorage.recordTransferBroadcast` therefore takes the resolved
//  `transferId` and appends against THAT row; the positional guess survives only as the
//  `nil`/unmatched fallback, and these tests pin both halves.
//
//  Fixture conventions mirror MigrationSummaryDustTests (the committed-schedule builder) and
//  MigrationCacheWarmupTests (the fixed-bytes `AccountUUID`). Serialized: the storage under test
//  writes through a named `UserDefaults` suite, which is process-global state.
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct MigrationSentRecordAttributionTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x31, count: 16))
    private static let now = Date(timeIntervalSince1970: 1_754_300_000)
    private static let suiteName = "MigrationSentRecordAttributionTests"

    /// Three transfers whose ARRAY (crossing) order deliberately inverts their slot order:
    /// id 0 broadcasts last, id 2 first — the exact shape where a positional guess and the
    /// engine's delivery disagree.
    private static func transfer(id: UInt32, slot: BlockHeight, zatoshi: Int64) -> MigrationTransferProposal {
        MigrationTransferProposal(
            id: id,
            amount: Zatoshi(zatoshi),
            anchorHeight: BlockHeight(3_000_000),
            nextExecutableAfterHeight: slot,
            expiryHeight: slot + 40
        )
    }

    private static func schedule() -> MigrationSchedule {
        MigrationSchedule(
            transfers: [
                transfer(id: 0, slot: BlockHeight(3_000_300), zatoshi: 100_000_000),
                transfer(id: 1, slot: BlockHeight(3_000_200), zatoshi: 200_000_000),
                transfer(id: 2, slot: BlockHeight(3_000_100), zatoshi: 500_000_000)
            ],
            estimatedDurationHours: 0,
            proposalHandle: 0,
            preparations: []
        )
    }

    /// A fresh storage over a wiped named suite, pre-seeded with the committed schedule.
    private static func makeStorage() -> MigrationScheduleStorage {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let storage = MigrationScheduleStorage(userDefaults: defaults)
        storage.recordCommittedSchedule(schedule(), for: accountUUID, now: now)
        return storage
    }

    private static func recordedIds(_ storage: MigrationScheduleStorage) -> [String] {
        (storage.committedSchedule(for: accountUUID)?.sentRecords ?? []).map { $0.transferId }
    }

    // MARK: - The fix

    /// THE test. The engine served transfer 2 (the slot-earliest); the array-first unsent row is
    /// transfer 0. The record must name 2, with 2's amount — never the positional guess.
    @Test func theServedIdWinsOverThePositionalGuess() {
        let storage = Self.makeStorage()

        storage.recordTransferBroadcast(
            MigrationTransferResult.success(txId: "aa11"),
            transferId: 2,
            for: Self.accountUUID,
            now: Self.now
        )

        let records = storage.committedSchedule(for: Self.accountUUID)?.sentRecords ?? []
        #expect(records.map { $0.transferId } == ["2"])
        #expect(records.first?.amount == Zatoshi(500_000_000))
        #expect(records.first?.txId == "aa11")
    }

    /// Delivery continues in slot order across calls: 2, then 1 — each record keyed to its own row.
    @Test func sequentialBroadcastsEachKeyTheirOwnRow() {
        let storage = Self.makeStorage()

        storage.recordTransferBroadcast(
            MigrationTransferResult.success(txId: "aa11"),
            transferId: 2,
            for: Self.accountUUID,
            now: Self.now
        )
        storage.recordTransferBroadcast(
            MigrationTransferResult.success(txId: "bb22"),
            transferId: 1,
            for: Self.accountUUID,
            now: Self.now
        )

        #expect(Self.recordedIds(storage) == ["2", "1"])
    }

    // MARK: - The pinned fallbacks

    /// `nil` id (nothing could vouch for the served row) keeps the legacy first-unsent guess —
    /// array order, so transfer 0.
    @Test func aNilIdKeepsTheLegacyFirstUnsentGuess() {
        let storage = Self.makeStorage()

        storage.recordTransferBroadcast(
            MigrationTransferResult.success(txId: "cc33"),
            transferId: nil,
            for: Self.accountUUID,
            now: Self.now
        )

        #expect(Self.recordedIds(storage) == ["0"])
    }

    /// A resolved id the persisted schedule cannot place (stale payload, refreshed run) degrades
    /// to the guess rather than dropping a landed broadcast's record.
    @Test func anUnknownIdFallsBackToTheGuess() {
        let storage = Self.makeStorage()

        storage.recordTransferBroadcast(
            MigrationTransferResult.success(txId: "dd44"),
            transferId: 9,
            for: Self.accountUUID,
            now: Self.now
        )

        #expect(Self.recordedIds(storage) == ["0"])
    }

    /// An id that already carries a record (a re-delivered result replay) also degrades to the
    /// guess — never a duplicate record for the same transfer.
    @Test func anAlreadyRecordedIdFallsBackToTheGuess() {
        let storage = Self.makeStorage()

        storage.recordTransferBroadcast(
            MigrationTransferResult.success(txId: "aa11"),
            transferId: 2,
            for: Self.accountUUID,
            now: Self.now
        )
        storage.recordTransferBroadcast(
            MigrationTransferResult.success(txId: "ee55"),
            transferId: 2,
            for: Self.accountUUID,
            now: Self.now
        )

        #expect(Self.recordedIds(storage) == ["2", "0"])
    }

    /// Non-success results record nothing, id or no id — unchanged contract.
    @Test func aFailureResultRecordsNothing() {
        let storage = Self.makeStorage()

        storage.recordTransferBroadcast(
            MigrationTransferResult.networkError(retryable: true),
            transferId: 2,
            for: Self.accountUUID,
            now: Self.now
        )

        #expect(Self.recordedIds(storage).isEmpty)
    }
}
