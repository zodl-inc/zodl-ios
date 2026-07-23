//
//  MigrationScheduleStorageTests.swift
//  zodlTests
//
//  Covers `MigrationScheduleStorage` (Dependencies/MigrationManager/MigrationManagerLiveKey.swift)
//  and the new `MigrationDerivations.transferRows`/`summary` pure functions for MOB-1496 W2: the
//  SDK retains no proposal list once a schedule is committed, so the app persists it here and
//  derives status rows/summaries from it plus live SDK flags. `.serialized`: every storage test
//  shares the `UserDefaults` global (same reasoning as `MigrationManagerTests`'s class-level doc).
//

import Testing
import Foundation
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized)
struct MigrationScheduleStorageTests {
    private static func accountUUID(_ byte: UInt8) -> AccountUUID {
        AccountUUID(id: [UInt8](repeating: byte, count: 16))
    }

    /// `nextExecutableAfterHeight` defaults to `anchorHeight` (every pre-A3 call site's behavior,
    /// unchanged) — pass it explicitly to control a row's real forward ETA independently of its
    /// anchor (MOB-1513 A3).
    private static func transfer(
        id: String,
        amount: Int64,
        anchorHeight: BlockHeight = 100,
        nextExecutableAfterHeight: BlockHeight? = nil
    ) -> MigrationTransferProposal {
        MigrationTransferProposal(
            id: id,
            amount: Zatoshi(amount),
            anchorHeight: anchorHeight,
            nextExecutableAfterHeight: nextExecutableAfterHeight ?? anchorHeight,
            expiryHeight: anchorHeight + 100
        )
    }

    private func withStorage(
        _ name: String,
        _ body: (MigrationScheduleStorage) throws -> Void
    ) throws {
        let userDefaults = try #require(UserDefaults(suiteName: name), "MigrationScheduleStorage: UserDefaults failed to initialize")
        defer { userDefaults.removePersistentDomain(forName: name) }
        try body(MigrationScheduleStorage(userDefaults: userDefaults))
    }

    // MARK: - Round-trip: record -> read

    @Test func committedScheduleIsNilBeforeAnyRecord() throws {
        try withStorage("testCommittedScheduleIsNilBeforeAnyRecord") { storage in
            let accountUUID = Self.accountUUID(1)
            #expect(storage.committedSchedule(for: accountUUID) == nil)
            #expect(storage.hasStoredPayload(for: accountUUID) == false)
        }
    }

    @Test func recordCommittedScheduleThenReadReturnsItWithEmptySentRecords() throws {
        try withStorage("testRecordCommittedScheduleThenReadReturnsItWithEmptySentRecords") { storage in
            let accountUUID = Self.accountUUID(2)
            let schedule = MigrationSchedule(transfers: [Self.transfer(id: "t0", amount: 100)], estimatedDurationHours: 6)
            let committedAt = Date(timeIntervalSince1970: 1_000_000)

            storage.recordCommittedSchedule(schedule, for: accountUUID, now: committedAt)

            let payload = try #require(storage.committedSchedule(for: accountUUID))
            #expect(payload.schedule == schedule)
            #expect(payload.sentRecords == [])
            #expect(payload.committedAt == committedAt)
            #expect(storage.hasStoredPayload(for: accountUUID) == true)
        }
    }

    @Test func recordCommittedScheduleReplacesSchedulePreservingSentRecordsOnRecommit() throws {
        try withStorage("testRecordCommittedScheduleReplacesSchedulePreservingSentRecordsOnRecommit") { storage in
            let accountUUID = Self.accountUUID(3)
            let firstSchedule = MigrationSchedule(transfers: [Self.transfer(id: "t0", amount: 100)], estimatedDurationHours: 6)
            storage.recordCommittedSchedule(firstSchedule, for: accountUUID, now: Date(timeIntervalSince1970: 1_000))
            storage.recordTransferBroadcast(
                MigrationTransferResult.success(txId: "tx0"),
                for: accountUUID,
                now: Date(timeIntervalSince1970: 2_000)
            )

            // Simulates a restart / re-created plan: a fresh schedule (new transfer ids) commits
            // over the old one.
            let secondSchedule = MigrationSchedule(transfers: [Self.transfer(id: "t1", amount: 200)], estimatedDurationHours: 12)
            storage.recordCommittedSchedule(secondSchedule, for: accountUUID, now: Date(timeIntervalSince1970: 3_000))

            let payload = try #require(storage.committedSchedule(for: accountUUID))
            #expect(payload.schedule == secondSchedule)
            #expect(payload.committedAt == Date(timeIntervalSince1970: 3_000))
            #expect(payload.sentRecords.count == 1)
            #expect(payload.sentRecords.first?.transferId == "t0")
        }
    }

    // MARK: - Round-trip: append on broadcast success

    @Test func recordTransferBroadcastAppendsSentRecordForFirstUnsentTransferInScheduleOrder() throws {
        try withStorage("testRecordTransferBroadcastAppendsSentRecordForFirstUnsentTransferInScheduleOrder") { storage in
            let accountUUID = Self.accountUUID(4)
            let schedule = MigrationSchedule(
                transfers: [Self.transfer(id: "t0", amount: 100), Self.transfer(id: "t1", amount: 200)],
                estimatedDurationHours: 12
            )
            storage.recordCommittedSchedule(schedule, for: accountUUID, now: Date(timeIntervalSince1970: 1_000))

            storage.recordTransferBroadcast(
                MigrationTransferResult.success(txId: "tx0"),
                for: accountUUID,
                now: Date(timeIntervalSince1970: 2_000)
            )

            var payload = try #require(storage.committedSchedule(for: accountUUID))
            #expect(payload.sentRecords.count == 1)
            #expect(payload.sentRecords[0].transferId == "t0")
            #expect(payload.sentRecords[0].amount == Zatoshi(100))
            #expect(payload.sentRecords[0].txId == "tx0")
            #expect(payload.sentRecords[0].sentAt == Date(timeIntervalSince1970: 2_000))

            storage.recordTransferBroadcast(
                MigrationTransferResult.success(txId: "tx1"),
                for: accountUUID,
                now: Date(timeIntervalSince1970: 3_000)
            )

            payload = try #require(storage.committedSchedule(for: accountUUID))
            #expect(payload.sentRecords.count == 2)
            #expect(payload.sentRecords[1].transferId == "t1")
        }
    }

    @Test func recordTransferBroadcastWithEmptyTxIdPersistsNilNotEmptyString() throws {
        try withStorage("testRecordTransferBroadcastWithEmptyTxIdPersistsNilNotEmptyString") { storage in
            let accountUUID = Self.accountUUID(5)
            let schedule = MigrationSchedule(transfers: [Self.transfer(id: "t0", amount: 100)], estimatedDurationHours: 6)
            storage.recordCommittedSchedule(schedule, for: accountUUID, now: Date())

            // The "record failed after broadcast" placeholder — the broadcast landed, only the
            // engine's own recording of it failed — must persist as `nil`, not `""`.
            storage.recordTransferBroadcast(MigrationTransferResult.success(txId: ""), for: accountUUID, now: Date())

            #expect(storage.committedSchedule(for: accountUUID)?.sentRecords.first?.txId == nil)
        }
    }

    @Test func recordTransferBroadcastWithNonSuccessResultAppendsNothing() throws {
        try withStorage("testRecordTransferBroadcastWithNonSuccessResultAppendsNothing") { storage in
            let accountUUID = Self.accountUUID(6)
            let schedule = MigrationSchedule(transfers: [Self.transfer(id: "t0", amount: 100)], estimatedDurationHours: 6)
            storage.recordCommittedSchedule(schedule, for: accountUUID, now: Date())

            storage.recordTransferBroadcast(MigrationTransferResult.networkError(retryable: true), for: accountUUID, now: Date())
            storage.recordTransferBroadcast(MigrationTransferResult.invalidNote, for: accountUUID, now: Date())
            storage.recordTransferBroadcast(MigrationTransferResult.expired, for: accountUUID, now: Date())

            #expect(storage.committedSchedule(for: accountUUID)?.sentRecords.isEmpty == true)
        }
    }

    @Test func recordTransferBroadcastWithNoExistingPayloadIsANoOp() throws {
        try withStorage("testRecordTransferBroadcastWithNoExistingPayloadIsANoOp") { storage in
            let accountUUID = Self.accountUUID(7)
            storage.recordTransferBroadcast(MigrationTransferResult.success(txId: "tx0"), for: accountUUID, now: Date())
            #expect(storage.committedSchedule(for: accountUUID) == nil)
        }
    }

    @Test func recordTransferBroadcastWhenEveryTransferAlreadySentAppendsNothing() throws {
        try withStorage("testRecordTransferBroadcastWhenEveryTransferAlreadySentAppendsNothing") { storage in
            let accountUUID = Self.accountUUID(8)
            let schedule = MigrationSchedule(transfers: [Self.transfer(id: "t0", amount: 100)], estimatedDurationHours: 6)
            storage.recordCommittedSchedule(schedule, for: accountUUID, now: Date())
            storage.recordTransferBroadcast(MigrationTransferResult.success(txId: "tx0"), for: accountUUID, now: Date())
            storage.recordTransferBroadcast(MigrationTransferResult.success(txId: "tx-extra"), for: accountUUID, now: Date())

            #expect(storage.committedSchedule(for: accountUUID)?.sentRecords.count == 1)
        }
    }

    // MARK: - Round-trip: clear + per-account isolation

    @Test func clearRemovesThePayload() throws {
        try withStorage("testClearRemovesThePayload") { storage in
            let accountUUID = Self.accountUUID(9)
            let schedule = MigrationSchedule(transfers: [Self.transfer(id: "t0", amount: 100)], estimatedDurationHours: 6)
            storage.recordCommittedSchedule(schedule, for: accountUUID, now: Date())
            #expect(storage.hasStoredPayload(for: accountUUID) == true)

            storage.clear(for: accountUUID)

            #expect(storage.hasStoredPayload(for: accountUUID) == false)
        }
    }

    @Test func perAccountPayloadsAreIsolated() throws {
        try withStorage("testPerAccountPayloadsAreIsolated") { storage in
            let accountA = Self.accountUUID(10)
            let accountB = Self.accountUUID(11)
            let schedule = MigrationSchedule(transfers: [Self.transfer(id: "t0", amount: 100)], estimatedDurationHours: 6)

            storage.recordCommittedSchedule(schedule, for: accountA, now: Date())

            #expect(storage.hasStoredPayload(for: accountA) == true)
            #expect(storage.hasStoredPayload(for: accountB) == false)
        }
    }

    @Test func payloadPersistsAcrossStorageInstancesUsingTheSameSuite() throws {
        // NOT `withStorage(_:_:)` here — its `defer` would wipe the suite the moment the first
        // closure returns, before a second instance ever gets to read it. Matches
        // `MigrationGateStorage`'s `gateStatePersistsAcrossStorageInstancesUsingTheSameSuite`.
        let suiteName = "testPayloadPersistsAcrossStorageInstancesUsingTheSameSuite"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let accountUUID = Self.accountUUID(12)
        let schedule = MigrationSchedule(transfers: [Self.transfer(id: "t0", amount: 100)], estimatedDurationHours: 6)

        let firstStorage = MigrationScheduleStorage(userDefaults: userDefaults)
        firstStorage.recordCommittedSchedule(schedule, for: accountUUID, now: Date(timeIntervalSince1970: 1_000))

        // A fresh instance over the same UserDefaults suite (simulating relaunch) must observe
        // the persisted payload, not start empty.
        let secondStorage = MigrationScheduleStorage(userDefaults: userDefaults)
        #expect(secondStorage.committedSchedule(for: accountUUID)?.schedule.transfers.first?.id == "t0")
    }

    // MARK: - Derivation: transferRows row-status precedence

    @Test func transferRowsFirstNonSentIsActiveWhenNothingIsWrong() {
        // MOB-1513 (A3): t0 sits AT the tip (ready now); t1 is 48 blocks out (48 × 75s = 3,600s =
        // 1h) — a real per-transfer height now drives the ETA, not the row's position.
        let schedule = MigrationSchedule(
            transfers: [
                Self.transfer(id: "t0", amount: 100, nextExecutableAfterHeight: 1_000),
                Self.transfer(id: "t1", amount: 200, nextExecutableAfterHeight: 1_048)
            ],
            estimatedDurationHours: 12
        )
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: [], committedAt: Date())

        let rows = MigrationDerivations.transferRows(
            committedSchedule: committed,
            state: MigrationState.notStarted,
            hasOverdueMigrationTransfers: false,
            now: Date(),
            currentTip: 1_000
        )

        #expect(rows.map(\.status) == [MigrationTransferRow.Status.active, MigrationTransferRow.Status.pending])
        #expect(rows.map(\.id) == ["t0", "t1"])
        #expect(rows.map(\.index) == [0, 1])
        #expect(rows[0].hoursFromNow == 0)
        #expect(rows[0].minutesFromNow == 0)
        #expect(rows[1].hoursFromNow == 1)
        #expect(rows[1].minutesFromNow == 60)
        #expect(rows.map(\.amount) == [Zatoshi(100), Zatoshi(200)])
    }

    @Test func transferRowsFirstNonSentIsOverdueWhenHasOverdueIsTrue() {
        let schedule = MigrationSchedule(
            transfers: [Self.transfer(id: "t0", amount: 100), Self.transfer(id: "t1", amount: 200)],
            estimatedDurationHours: 12
        )
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: [], committedAt: Date())

        let rows = MigrationDerivations.transferRows(
            committedSchedule: committed,
            state: MigrationState.notStarted,
            hasOverdueMigrationTransfers: true,
            now: Date(),
            currentTip: 100
        )

        #expect(rows.map(\.status) == [MigrationTransferRow.Status.overdue, MigrationTransferRow.Status.pending])
    }

    @Test func transferRowsMarksInvalidByIdMatchRegardlessOfPosition() {
        let schedule = MigrationSchedule(
            transfers: [
                Self.transfer(id: "t0", amount: 100),
                Self.transfer(id: "t1", amount: 200),
                Self.transfer(id: "t2", amount: 300)
            ],
            estimatedDurationHours: 18
        )
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: [], committedAt: Date())

        // The invalid transfer is t1 — NOT the first non-sent row (t0) — so t0 stays `.active`
        // (unaffected), t1 reads `.invalid`, and t2 (never the first non-sent row) stays `.pending`.
        let rows = MigrationDerivations.transferRows(
            committedSchedule: committed,
            state: MigrationState.requiresAttention(MigrationAttentionReason.invalidTransfer(transferId: "t1")),
            hasOverdueMigrationTransfers: false,
            now: Date(),
            currentTip: 100
        )

        #expect(rows.map(\.status) == [
            MigrationTransferRow.Status.active,
            MigrationTransferRow.Status.invalid,
            MigrationTransferRow.Status.pending
        ])
    }

    @Test func transferRowsWhenFirstNonSentRowIsInvalidLaterRowsStayPendingNotPromoted() {
        // Documents the derivation's precedence: "first non-sent" is a FIXED position, not
        // re-evaluated once an earlier row is claimed by the position-independent invalid check —
        // so when the first non-sent row itself is the invalid one, nothing promotes the next row
        // to active/overdue; it stays `.pending` like every row after the first.
        let schedule = MigrationSchedule(
            transfers: [Self.transfer(id: "t0", amount: 100), Self.transfer(id: "t1", amount: 200)],
            estimatedDurationHours: 12
        )
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: [], committedAt: Date())

        let rows = MigrationDerivations.transferRows(
            committedSchedule: committed,
            state: MigrationState.requiresAttention(MigrationAttentionReason.invalidTransfer(transferId: "t0")),
            hasOverdueMigrationTransfers: false,
            now: Date(),
            currentTip: 100
        )

        #expect(rows.map(\.status) == [MigrationTransferRow.Status.invalid, MigrationTransferRow.Status.pending])
    }

    @Test func transferRowsMarksFirstNonSentExpiredWhenStateIsTransferExpired() {
        let schedule = MigrationSchedule(
            transfers: [Self.transfer(id: "t0", amount: 100), Self.transfer(id: "t1", amount: 200)],
            estimatedDurationHours: 12
        )
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: [], committedAt: Date())

        let rows = MigrationDerivations.transferRows(
            committedSchedule: committed,
            state: MigrationState.requiresAttention(MigrationAttentionReason.transferExpired),
            hasOverdueMigrationTransfers: false,
            now: Date(),
            currentTip: 100
        )

        #expect(rows.map(\.status) == [MigrationTransferRow.Status.expired, MigrationTransferRow.Status.pending])
    }

    @Test func transferRowsWithSentRecordMatchingAScheduleTransferReadsSentNotActive() {
        let schedule = MigrationSchedule(
            transfers: [Self.transfer(id: "t0", amount: 100), Self.transfer(id: "t1", amount: 200)],
            estimatedDurationHours: 12
        )
        let sentAt = Date(timeIntervalSince1970: 1_000)
        let sentRecords = [
            MigrationCommittedSchedule.SentRecord(transferId: "t0", amount: Zatoshi(100), txId: "tx0", sentAt: sentAt)
        ]
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: sentRecords, committedAt: Date())

        let rows = MigrationDerivations.transferRows(
            committedSchedule: committed,
            state: MigrationState.inProgress(
                MigrationProgress(completedTransfers: 1, totalTransfers: 2, remainingOrchard: .zero, nextTransferReadyAtHeight: nil)
            ),
            hasOverdueMigrationTransfers: false,
            now: sentAt.addingTimeInterval(600),
            currentTip: 100
        )

        #expect(rows.count == 2)
        #expect(rows[0].status == MigrationTransferRow.Status.sent)
        #expect(rows[0].sentMinutesAgo == 10)
        #expect(rows[0].hoursFromNow == 0)
        // The second (and now only non-sent) row is the first non-sent row -> `.active`. Its
        // height (100, t1's default) sits AT the tip (100) -> ready now.
        #expect(rows[1].status == MigrationTransferRow.Status.active)
        #expect(rows[1].hoursFromNow == 0)
        #expect(rows[1].minutesFromNow == 0)
    }

    @Test func transferRowsSentRowHoursAgoDropsSentMinutesAgoPastOneHour() {
        let schedule = MigrationSchedule(transfers: [Self.transfer(id: "t0", amount: 100)], estimatedDurationHours: 6)
        let sentAt = Date(timeIntervalSince1970: 1_000)
        let sentRecords = [
            MigrationCommittedSchedule.SentRecord(transferId: "t0", amount: Zatoshi(100), txId: "tx0", sentAt: sentAt)
        ]
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: sentRecords, committedAt: Date())

        let rows = MigrationDerivations.transferRows(
            committedSchedule: committed,
            state: MigrationState.complete,
            hasOverdueMigrationTransfers: false,
            now: sentAt.addingTimeInterval(2 * 3_600 + 300),
            currentTip: 100
        )

        #expect(rows[0].hoursFromNow == 2)
        #expect(rows[0].sentMinutesAgo == nil)
    }

    // MARK: - Derivation: prior-run sent rows prepended after a restart re-commit

    @Test func transferRowsPrependsPriorRunSentRowsNotInCurrentSchedule() {
        // Brief's worked example: 2 prior-run sent + 4 new schedule transfers (none sent again yet)
        // -> 6 rows, statuses [sent, sent, active, pending, pending, pending].
        let priorSentRecords = [
            MigrationCommittedSchedule.SentRecord(transferId: "old0", amount: Zatoshi(10), txId: "tx-old0", sentAt: Date(timeIntervalSince1970: 1_000)),
            MigrationCommittedSchedule.SentRecord(transferId: "old1", amount: Zatoshi(20), txId: "tx-old1", sentAt: Date(timeIntervalSince1970: 2_000))
        ]
        // MOB-1513 (A3): distinct real heights against a tip of 1_000 — new0 is AT the tip (ready
        // now), new1/new2/new3 are 48/96/192 blocks out (× 75s/block = 1h/2h/4h).
        let newSchedule = MigrationSchedule(
            transfers: [
                Self.transfer(id: "new0", amount: 100, nextExecutableAfterHeight: 1_000),
                Self.transfer(id: "new1", amount: 200, nextExecutableAfterHeight: 1_048),
                Self.transfer(id: "new2", amount: 300, nextExecutableAfterHeight: 1_096),
                Self.transfer(id: "new3", amount: 400, nextExecutableAfterHeight: 1_192)
            ],
            estimatedDurationHours: 24
        )
        let committed = MigrationCommittedSchedule(schedule: newSchedule, sentRecords: priorSentRecords, committedAt: Date(timeIntervalSince1970: 3_000))

        let rows = MigrationDerivations.transferRows(
            committedSchedule: committed,
            state: MigrationState.inProgress(
                MigrationProgress(completedTransfers: 2, totalTransfers: 4, remainingOrchard: .zero, nextTransferReadyAtHeight: nil)
            ),
            hasOverdueMigrationTransfers: false,
            now: Date(timeIntervalSince1970: 3_000),
            currentTip: 1_000
        )

        #expect(rows.count == 6)
        #expect(rows.map(\.id) == ["old0", "old1", "new0", "new1", "new2", "new3"])
        #expect(rows.map(\.index) == [0, 1, 2, 3, 4, 5])
        #expect(rows.map(\.status) == [
            MigrationTransferRow.Status.sent,
            MigrationTransferRow.Status.sent,
            MigrationTransferRow.Status.active,
            MigrationTransferRow.Status.pending,
            MigrationTransferRow.Status.pending,
            MigrationTransferRow.Status.pending
        ])
        // old0/old1 (sent) keep their elapsed-time-since-`sentAt` math, untouched by A3 (both under
        // an hour old here, so both floor to 0h). new0/new1/new2/new3 (non-sent) now read their
        // REAL per-transfer height against the tip — 0h/1h/2h/4h — not a `position × 6h` cadence.
        #expect(rows.map(\.hoursFromNow) == [0, 0, 0, 1, 2, 4])
        #expect(rows.map(\.minutesFromNow) == [nil, nil, 0, 60, 120, 240])
    }

    @Test func transferRowsWithNoPriorSentRecordsOutsideScheduleRendersScheduleRowsOnly() {
        let schedule = MigrationSchedule(transfers: [Self.transfer(id: "t0", amount: 100)], estimatedDurationHours: 6)
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: [], committedAt: Date())

        let rows = MigrationDerivations.transferRows(
            committedSchedule: committed,
            state: MigrationState.notStarted,
            hasOverdueMigrationTransfers: false,
            now: Date(),
            currentTip: 100
        )

        #expect(rows.count == 1)
        #expect(rows[0].id == "t0")
    }

    // MARK: - Derivation: transferRows real forward ETA (MOB-1513 A3)

    @Test func transferRowsSubHourPendingRowCarriesMinutePrecision() {
        // 20 blocks × 75s = 1,500s = 25 minutes — under an hour, so the row must carry the
        // minute-precise value (the caption reads "in ~25 mins", never floored to 0h).
        let schedule = MigrationSchedule(
            transfers: [Self.transfer(id: "t0", amount: 100, nextExecutableAfterHeight: 1_020)],
            estimatedDurationHours: 1
        )
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: [], committedAt: Date())

        let rows = MigrationDerivations.transferRows(
            committedSchedule: committed,
            state: MigrationState.notStarted,
            hasOverdueMigrationTransfers: false,
            now: Date(),
            currentTip: 1_000
        )

        #expect(rows[0].status == MigrationTransferRow.Status.active)
        #expect(rows[0].minutesFromNow == 25)
        #expect(rows[0].hoursFromNow == 0)
    }

    @Test func transferRowsBehindTipHeightReadsAsReadyNow() {
        // An overdue transfer's scheduled height sits BEHIND the live tip —
        // `MigrationETA.minutesFromNow` floors that to `0` ("Ready now"), never negative.
        let schedule = MigrationSchedule(
            transfers: [Self.transfer(id: "t0", amount: 100, nextExecutableAfterHeight: 900)],
            estimatedDurationHours: 1
        )
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: [], committedAt: Date())

        let rows = MigrationDerivations.transferRows(
            committedSchedule: committed,
            state: MigrationState.notStarted,
            hasOverdueMigrationTransfers: true,
            now: Date(),
            currentTip: 1_000
        )

        #expect(rows[0].status == MigrationTransferRow.Status.overdue)
        #expect(rows[0].minutesFromNow == 0)
        #expect(rows[0].hoursFromNow == 0)
    }

    @Test func transferRowsRederivesFromRefreshedHeightsNotStalePreRefreshOnes() {
        // R7's refresh lane (`refreshStaleMigrationTransfers`) persists its RETURNED schedule via
        // `recordCommittedSchedule` before this derivation ever runs again (see
        // `MigrationCoordFlowCoordinator`'s recovery-refresh lane) — this derivation takes
        // `committedSchedule` as a plain input and caches nothing, so re-deriving against the
        // freshly-persisted (refreshed) heights must produce a fresh ETA, never the stale
        // pre-refresh one, even at the identical tip.
        let tip = 1_000

        let staleSchedule = MigrationSchedule(
            transfers: [Self.transfer(id: "t0", amount: 100, nextExecutableAfterHeight: 900)],
            estimatedDurationHours: 1
        )
        let staleCommitted = MigrationCommittedSchedule(schedule: staleSchedule, sentRecords: [], committedAt: Date())
        let staleRows = MigrationDerivations.transferRows(
            committedSchedule: staleCommitted,
            state: MigrationState.requiresAttention(MigrationAttentionReason.transferExpired),
            hasOverdueMigrationTransfers: false,
            now: Date(),
            currentTip: tip
        )
        #expect(staleRows[0].minutesFromNow == 0)

        // The refresh rebuilds the transfer in place with a fresh, FUTURE height and re-commits
        // (`recordCommittedSchedule` replaces `schedule` wholesale — see
        // `recordCommittedScheduleReplacesSchedulePreservingSentRecordsOnRecommit` above).
        let refreshedSchedule = MigrationSchedule(
            transfers: [Self.transfer(id: "t0", amount: 100, nextExecutableAfterHeight: 1_096)],
            estimatedDurationHours: 2
        )
        let refreshedCommitted = MigrationCommittedSchedule(schedule: refreshedSchedule, sentRecords: [], committedAt: Date())
        let refreshedRows = MigrationDerivations.transferRows(
            committedSchedule: refreshedCommitted,
            state: MigrationState.notStarted,
            hasOverdueMigrationTransfers: false,
            now: Date(),
            currentTip: tip
        )

        #expect(refreshedRows[0].minutesFromNow == 120)
        #expect(refreshedRows[0].hoursFromNow == 2)
    }

    // MARK: - Derivation: summary math

    @Test func summaryTransferredAndTotalsAcrossRestart() {
        let priorSentRecords = [
            MigrationCommittedSchedule.SentRecord(transferId: "old0", amount: Zatoshi(10), txId: "tx-old0", sentAt: Date(timeIntervalSince1970: 1_000)),
            MigrationCommittedSchedule.SentRecord(transferId: "old1", amount: Zatoshi(20), txId: "tx-old1", sentAt: Date(timeIntervalSince1970: 2_000))
        ]
        let newSchedule = MigrationSchedule(
            transfers: [
                Self.transfer(id: "new0", amount: 100),
                Self.transfer(id: "new1", amount: 200),
                Self.transfer(id: "new2", amount: 300),
                Self.transfer(id: "new3", amount: 400)
            ],
            estimatedDurationHours: 24
        )
        let committed = MigrationCommittedSchedule(schedule: newSchedule, sentRecords: priorSentRecords, committedAt: Date())

        let summary = MigrationDerivations.summary(
            committedSchedule: committed,
            state: MigrationState.inProgress(
                MigrationProgress(completedTransfers: 2, totalTransfers: 4, remainingOrchard: .zero, nextTransferReadyAtHeight: nil)
            ),
            residual: Zatoshi(555),
            progress: nil
        )

        #expect(summary.transferred == Zatoshi(30))
        #expect(summary.transfersSent == 2)
        #expect(summary.transfersTotal == 6)
        #expect(summary.estimatedDurationHours == 24)
        #expect(summary.dust == Zatoshi(555))
    }

    @Test func summaryTransfersTotalExcludesScheduleTransfersAlreadyCoveredByASentRecord() {
        // A schedule transfer that already has a matching sent record must not be double-counted
        // in the "still unsent" half of `transfersTotal`.
        let schedule = MigrationSchedule(
            transfers: [Self.transfer(id: "t0", amount: 100), Self.transfer(id: "t1", amount: 200)],
            estimatedDurationHours: 12
        )
        let sentRecords = [
            MigrationCommittedSchedule.SentRecord(transferId: "t0", amount: Zatoshi(100), txId: "tx0", sentAt: Date())
        ]
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: sentRecords, committedAt: Date())

        let summary = MigrationDerivations.summary(
            committedSchedule: committed,
            state: MigrationState.inProgress(
                MigrationProgress(completedTransfers: 1, totalTransfers: 2, remainingOrchard: .zero, nextTransferReadyAtHeight: nil)
            ),
            residual: Zatoshi.zero,
            progress: nil
        )

        #expect(summary.transfersSent == 1)
        #expect(summary.transfersTotal == 2)
    }

    @Test func summaryDustFallsBackToZeroWhenResidualUnavailableAndNotComplete() {
        let schedule = MigrationSchedule(transfers: [Self.transfer(id: "t0", amount: 100)], estimatedDurationHours: 6)
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: [], committedAt: Date())

        let summary = MigrationDerivations.summary(
            committedSchedule: committed,
            state: MigrationState.notStarted,
            residual: nil,
            progress: nil
        )

        #expect(summary.dust == Zatoshi.zero)
    }

    @Test func summaryDustFallsBackToProgressRemainingOrchardWhenCompleteAndResidualUnavailable() {
        let schedule = MigrationSchedule(transfers: [Self.transfer(id: "t0", amount: 100)], estimatedDurationHours: 6)
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: [], committedAt: Date())
        let progress = MigrationProgress(completedTransfers: 1, totalTransfers: 1, remainingOrchard: Zatoshi(777), nextTransferReadyAtHeight: nil)

        // Simulates a `try? residualAfterMigration(...)` that threw or returned `nil`.
        let summary = MigrationDerivations.summary(
            committedSchedule: committed,
            state: MigrationState.complete,
            residual: nil,
            progress: progress
        )

        #expect(summary.dust == Zatoshi(777))
    }

    @Test func summaryDustPrefersResidualEvenWhenComplete() {
        let schedule = MigrationSchedule(transfers: [Self.transfer(id: "t0", amount: 100)], estimatedDurationHours: 6)
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: [], committedAt: Date())
        let progress = MigrationProgress(completedTransfers: 1, totalTransfers: 1, remainingOrchard: Zatoshi(777), nextTransferReadyAtHeight: nil)

        let summary = MigrationDerivations.summary(
            committedSchedule: committed,
            state: MigrationState.complete,
            residual: Zatoshi(1),
            progress: progress
        )

        #expect(summary.dust == Zatoshi(1))
    }

    @Test func summaryDustFallsBackToZeroWhenCompleteAndNeitherResidualNorProgressAreAvailable() {
        let schedule = MigrationSchedule(transfers: [Self.transfer(id: "t0", amount: 100)], estimatedDurationHours: 6)
        let committed = MigrationCommittedSchedule(schedule: schedule, sentRecords: [], committedAt: Date())

        let summary = MigrationDerivations.summary(
            committedSchedule: committed,
            state: MigrationState.complete,
            residual: nil,
            progress: nil
        )

        #expect(summary.dust == Zatoshi.zero)
    }
}
