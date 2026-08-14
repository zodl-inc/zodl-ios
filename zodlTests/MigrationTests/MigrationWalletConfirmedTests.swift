//
//  MigrationWalletConfirmedTests.swift
//  zodlTests
//
//  GROUND_RULES R11 (2026-08-03): user-facing DONE = WALLET-CONFIRMED. A transfer renders green
//  only when the WALLET's own store has observed it mined — the same standard Activity and the home
//  balances use — not at broadcast success (the old rule; how the field got three green checks
//  summing 55.2 ZEC over an Ironwood balance of 0) and not at engine-mined either, which is one
//  ~privacy-window earlier (the SDK deliberately holds sync 180 s testnet / 600 s mainnet after a
//  broadcast, so the wallet cannot yet have counted what the engine already calls mined).
//
//  The mechanism is `MigrationTransferRow.Status.confirming` plus one input: `confirmedTxIds`, the
//  display-form hex txids the wallet's own store has observed mined. These tests pin the three-way
//  judgment that replaced the old boolean "sent" — for every lane that renders rows
//  (`transferRows`, `statusOnlyTransferRows`, `preparationRows`) — and the banner consequences:
//  counts come from the ROWS (R5), `.complete` never renders over a confirming timeline (R4), and
//  a confirming row is never the "Transfer N" an actionable banner names.
//
//  The deliberate, narrow fallbacks are pinned too, because they are the part a refactor would
//  flatten first:
//  - `confirmedTxIds == nil` (no wallet read has EVER succeeded) keeps ENGINE truth for
//    engine-MINED rows — but a merely-broadcast row is `.confirming` even then. nil is NOT
//    pre-R11: broadcast success alone is never green again.
//  - engine-mined with NO matchable txid (record failed after broadcast, or a preparation whose
//    remembered txid died with the app) keeps engine truth — a row that can never match must not
//    read "Confirming…" forever.
//
//  Fixture conventions mirror MigrationBannerRowTruthTests (Self.row / Self.variant /
//  Self.progress) and MigrationSummaryDustTests (the committed-schedule builder).
//

import Foundation
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationWalletConfirmedTests {
    // MARK: - Fixtures

    private static let clock = MigrationChainClock(tip: 3_000_000)
    private static let now = Date(timeIntervalSince1970: 1_754_200_000)

    /// A txid as the engine's `.broadcast(txid:)` payload carries it: RAW byte order. The wallet's
    /// store (and `SentRecord.txId`, and `TransactionState.id`) all speak DISPLAY-form hex
    /// (`Data.toHexStringTxId()`, reversed byte order), so every set-membership fixture below that
    /// matches a live-broadcast payload must insert `rawTxid.toHexStringTxId()` — never the raw
    /// hex — or it would be testing a comparison production never makes.
    private static let rawTxid = Data([0xdd, 0x87, 0x92, 0xff, 0x01, 0x02, 0x03, 0x04])
    private static var displayTxid: String { rawTxid.toHexStringTxId() }

    /// A `SentRecord.txId` — already display-form by the SDK's own `success(txId:)` convention.
    private static let recordedTxId = "aa11bb22cc33dd44"
    /// A txid the wallet HAS seen mined but which belongs to some other transaction — a non-nil,
    /// non-empty set that still must not green the row under test.
    private static let unrelatedTxId = "beefbeefbeefbeef"

    private static func sentRecord(transferId: String = "1", txId: String? = recordedTxId) -> MigrationCommittedSchedule.SentRecord {
        MigrationCommittedSchedule.SentRecord(
            transferId: transferId,
            amount: Zatoshi(100_000_000),
            txId: txId,
            sentAt: Self.now.addingTimeInterval(-120)
        )
    }

    /// A one-transfer committed schedule (engine id 1 — so the row id and the live-status join key
    /// are both "1"), with whatever sent records the case under test needs.
    private static func committedSchedule(sentRecords: [MigrationCommittedSchedule.SentRecord]) -> MigrationCommittedSchedule {
        MigrationCommittedSchedule(
            schedule: MigrationSchedule(
                transfers: [
                    MigrationTransferProposal(
                        id: 1,
                        amount: Zatoshi(100_000_000),
                        anchorHeight: 2_999_900,
                        nextExecutableAfterHeight: 2_999_990,
                        expiryHeight: 3_040_000
                    )
                ],
                estimatedDurationHours: 1,
                proposalHandle: 0,
                preparations: []
            ),
            sentRecords: sentRecords,
            committedAt: Date(timeIntervalSince1970: 1_754_100_000)
        )
    }

    private static func transferStatus(id: UInt32 = 1, state: MigrationTransactionStatus.State) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: .transfer(crossing: 0),
            state: state,
            scheduledHeight: 2_999_990,
            expiryHeight: nil,
            isReady: false,
            nextAction: nil,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    private static func preparationStatus(id: UInt32 = 7, state: MigrationTransactionStatus.State) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: .preparation(layer: 0, index: 0),
            state: state,
            scheduledHeight: 2_999_990,
            expiryHeight: nil,
            isReady: false,
            nextAction: nil,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    /// The schedule-lane derivation under test, with everything not under test held constant.
    private static func rows(
        sentRecords: [MigrationCommittedSchedule.SentRecord],
        statuses: [MigrationTransactionStatus] = [],
        confirmedTxIds: Set<String>?
    ) -> [MigrationTransferRow] {
        MigrationDerivations.transferRows(
            committedSchedule: Self.committedSchedule(sentRecords: sentRecords),
            state: .inProgress(Self.progress(completed: 0, total: 1)),
            hasOverdueMigrationTransfers: false,
            now: Self.now,
            clock: Self.clock,
            statuses: statuses,
            confirmedTxIds: confirmedTxIds
        )
    }

    private static func progress(completed: Int, total: Int) -> MigrationProgress {
        MigrationProgress(
            completedTransfers: completed,
            totalTransfers: total,
            remainingOrchard: Zatoshi(500_000_000),
            nextTransferReadyAtHeight: 3_000_000,
            isImmediate: false
        )
    }

    private static func row(
        index: Int,
        status: MigrationTransferRow.Status,
        isBroadcasting: Bool = false,
        kind: MigrationTransferRow.Kind = .transfer,
        isPreparing: Bool = false
    ) -> MigrationTransferRow {
        MigrationTransferRow(
            id: "\(index)",
            index: index,
            amount: Zatoshi(100_000_000),
            status: status,
            hoursFromNow: 0,
            isBroadcasting: isBroadcasting,
            isPreparing: isPreparing,
            kind: kind
        )
    }

    private static func variant(
        state: MigrationState,
        transferRows: [MigrationTransferRow],
        preparationRows: [MigrationTransferRow] = []
    ) -> MigrationBannerVariant? {
        MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: state,
            orchardBalance: Zatoshi(500_000_000),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: transferRows,
            preparationRows: preparationRows
        )
    }

    // MARK: - A. transferRows: the three-way judgment

    /// THE R11 core. A `sentRecord` exists the moment a broadcast RETURNS SUCCESS — two phases
    /// before the transfer has pool impact — and before R11 that alone rendered the green check.
    /// With a wallet read in hand (`confirmedTxIds` non-nil) that has not seen this txid, the row
    /// is `.confirming`: on the chain's side, wallet not yet counted it. Green no longer fires at
    /// broadcast.
    @Test func aBroadcastSuccessAloneIsConfirmingNotSent() {
        let rows = Self.rows(
            sentRecords: [Self.sentRecord()],
            confirmedTxIds: [Self.unrelatedTxId]
        )
        #expect(rows[0].status == .confirming)
    }

    /// The moment the wallet's own store has the recorded txid mined, the same row is `.sent` —
    /// the one standard every green in the app shares.
    @Test func aWalletConfirmedRecordIsSent() {
        let rows = Self.rows(
            sentRecords: [Self.sentRecord()],
            confirmedTxIds: [Self.recordedTxId]
        )
        #expect(rows[0].status == .sent)
    }

    /// Mined per the ENGINE is not done — it is one privacy-window early. The engine's tables can
    /// call a transfer mined while the SDK still holds sync (180 s testnet / 600 s mainnet), so
    /// the wallet's store — the source Activity and the home balances render from — has not
    /// counted it. Until it does, `.confirming`.
    @Test func engineMinedButWalletUnseenIsConfirming() {
        let rows = Self.rows(
            sentRecords: [Self.sentRecord()],
            statuses: [Self.transferStatus(state: .mined(height: 2_999_995))],
            confirmedTxIds: [Self.unrelatedTxId]
        )
        #expect(rows[0].status == .confirming)
    }

    /// Engine-mined AND wallet-confirmed: green, with no further condition.
    @Test func engineMinedAndWalletConfirmedIsSent() {
        let rows = Self.rows(
            sentRecords: [Self.sentRecord()],
            statuses: [Self.transferStatus(state: .mined(height: 2_999_995))],
            confirmedTxIds: [Self.recordedTxId]
        )
        #expect(rows[0].status == .sent)
    }

    /// The documented no-txid fallback: engine-mined with NO `sentRecord` at all (the
    /// record-failed-after-broadcast edge) has nothing to match against the set, and a row that
    /// can never match must not read "Confirming…" forever — engine truth stands.
    @Test func engineMinedWithNoRecordKeepsEngineTruth() {
        let rows = Self.rows(
            sentRecords: [],
            statuses: [Self.transferStatus(state: .mined(height: 2_999_995))],
            confirmedTxIds: [Self.unrelatedTxId]
        )
        #expect(rows[0].status == .sent)
    }

    /// `confirmedTxIds == nil` means no wallet read has EVER succeeded. Un-confirming the whole
    /// timeline over a read failure would repaint every green as "Confirming…" — a worse lie than
    /// the one R11 removes — so engine-MINED rows keep engine truth.
    @Test func aNilWalletReadKeepsEngineTruthForMinedRows() {
        let rows = Self.rows(
            sentRecords: [Self.sentRecord()],
            statuses: [Self.transferStatus(state: .mined(height: 2_999_995))],
            confirmedTxIds: nil
        )
        #expect(rows[0].status == .sent)
    }

    /// …but nil is NOT pre-R11. A broadcast-only row (sentRecord present, engine not mined) was
    /// never green-worthy, and stays `.confirming` even with no wallet read to consult. This is
    /// the half of the fallback a "nil restores old behaviour" refactor would silently break.
    @Test func aNilWalletReadNeverGreensABroadcastOnlyRow() {
        let rows = Self.rows(
            sentRecords: [Self.sentRecord()],
            confirmedTxIds: nil
        )
        #expect(rows[0].status == .confirming)
    }

    /// The wallet can know BEFORE the engine flips: the store's scan can observe the mining while
    /// the run's own tables still say `.broadcast`. The live payload carries the txid in RAW byte
    /// order; the set holds display-form hex (`Data.toHexStringTxId()`, reversed bytes), and the
    /// derivation must convert before matching — a raw-hex comparison would never hit.
    @Test func theWalletCanConfirmALiveBroadcastBeforeTheEngineFlips() {
        let rows = Self.rows(
            sentRecords: [],
            statuses: [Self.transferStatus(state: .broadcast(txid: Self.rawTxid))],
            confirmedTxIds: [Self.displayTxid]
        )
        #expect(rows[0].status == .sent)
    }

    /// A live `.broadcast` the wallet has not counted is `.confirming` AND still carries
    /// `isBroadcasting` — the flag the timeline's "Sent recently" caption and the banner's
    /// number-skipping read. R11 changed which rows are green, not which rows are on the wire.
    @Test func aConfirmingLiveBroadcastStillCarriesTheBroadcastFlag() {
        let rows = Self.rows(
            sentRecords: [],
            statuses: [Self.transferStatus(state: .broadcast(txid: Self.rawTxid))],
            confirmedTxIds: []
        )
        #expect(rows[0].status == .confirming)
        #expect(rows[0].isBroadcasting == true)
    }

    // MARK: - B. statusOnlyTransferRows: same gate, no schedule to lean on

    /// The W1 fallback lane (restore / fresh install, no persisted schedule) takes the same R11
    /// gate for its `.broadcast(txid:)` rows: display-form match against the wallet's set.
    @Test func statusOnlyBroadcastConfirmedByTheWalletIsSent() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.transferStatus(state: .broadcast(txid: Self.rawTxid))],
            clock: Self.clock,
            confirmedTxIds: [Self.displayTxid]
        )
        #expect(rows?[0].status == .sent)
    }

    /// Unconfirmed broadcast in the status-only lane: `.confirming`, still flagged on the wire.
    @Test func statusOnlyBroadcastUnconfirmedIsConfirming() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.transferStatus(state: .broadcast(txid: Self.rawTxid))],
            clock: Self.clock,
            confirmedTxIds: [Self.unrelatedTxId]
        )
        #expect(rows?[0].status == .confirming)
        #expect(rows?[0].isBroadcasting == true)
    }

    /// An engine-`.mined` row in this lane carries NO txid to match (the public model exposes only
    /// the height), and on the one device class that lives here the engine only learns mined-ness
    /// FROM the wallet's own scan — so `.mined` keeps engine truth even against a non-empty set
    /// that does not name it.
    @Test func statusOnlyMinedKeepsEngineTruth() {
        let rows = MigrationDerivations.statusOnlyTransferRows(
            statuses: [Self.transferStatus(state: .mined(height: 2_999_995))],
            clock: Self.clock,
            confirmedTxIds: [Self.unrelatedTxId]
        )
        #expect(rows?[0].status == .sent)
    }

    // MARK: - C. preparationRows: the remembered-txid join

    /// A preparation's `.mined` state carries no txid and has no `SentRecord`, so the manager
    /// remembers each broadcast-time txid per status id. Engine-mined but wallet-unseen — matched
    /// via that remembered txid — is `.confirming`: a split's "done" flips in the same sync write
    /// as every other green.
    @Test func aMinedPreparationTheWalletHasNotSeenIsConfirming() {
        let rows = MigrationDerivations.preparationRows(
            statuses: [Self.preparationStatus(state: .mined(height: 2_999_995))],
            clock: Self.clock,
            confirmedTxIds: [Self.unrelatedTxId],
            rememberedTxIds: [7: Self.displayTxid]
        )
        #expect(rows?[0].status == .confirming)
    }

    /// Remembered txid in the wallet's set: the split row is `.sent`.
    @Test func aWalletConfirmedPreparationIsSent() {
        let rows = MigrationDerivations.preparationRows(
            statuses: [Self.preparationStatus(state: .mined(height: 2_999_995))],
            clock: Self.clock,
            confirmedTxIds: [Self.displayTxid],
            rememberedTxIds: [7: Self.displayTxid]
        )
        #expect(rows?[0].status == .sent)
    }

    /// The app-kill degradation, documented at the cache: the remembered txids are in-memory, so a
    /// kill between broadcast and confirmation loses the join key. A mined preparation with no
    /// remembered txid keeps engine truth — degraded, never worse than pre-R11, never a
    /// "Confirming…" that can't resolve.
    @Test func aMinedPreparationWithNoRememberedTxidKeepsEngineTruth() {
        let rows = MigrationDerivations.preparationRows(
            statuses: [Self.preparationStatus(state: .mined(height: 2_999_995))],
            clock: Self.clock,
            confirmedTxIds: [Self.unrelatedTxId],
            rememberedTxIds: [:]
        )
        #expect(rows?[0].status == .sent)
    }

    /// A broadcast preparation carries its txid in the live payload, so no remembered join is
    /// needed: unconfirmed means `.confirming`, same as every other lane.
    @Test func aBroadcastPreparationUnconfirmedIsConfirming() {
        let rows = MigrationDerivations.preparationRows(
            statuses: [Self.preparationStatus(state: .broadcast(txid: Self.rawTxid))],
            clock: Self.clock,
            confirmedTxIds: [Self.unrelatedTxId],
            rememberedTxIds: [:]
        )
        #expect(rows?[0].status == .confirming)
    }

    // MARK: - D. bannerVariant under R11

    /// R5 made executable: the banner's counts come from the ROWS the screen renders, and a
    /// `.confirming` row does NOT count as done — it has no pool impact yet, and a "2 of 6" over a
    /// screen showing one green and one "Confirming…" is exactly the banner/screen split R11
    /// removes. The fixture's `progress` deliberately claims different counts (3 of 12) so this
    /// asserts provenance, not coincidence.
    /// Re-anchored onto `.preparing` for the ratified idle (2026-08-06): the original fixture had
    /// nothing in flight, which now renders `.idle` — a state with no counts to miscount — so the
    /// R11 claim is asserted where counts still render. One in-flight row raises `.preparing`,
    /// whose `done` comes from the same sent-row filter: the confirming row is in neither number.
    @Test func aConfirmingRowDoesNotCountAsDone() {
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: 3, total: 12)),
            transferRows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .confirming),
                Self.row(index: 2, status: .pending),
                Self.row(index: 3, status: .pending),
                Self.row(index: 4, status: .pending),
                Self.row(index: 5, status: .pending),
                Self.row(index: 6, status: .active, isPreparing: true)
            ]
        )
        #expect(variant == .preparing(done: 1, total: 7))
    }

    /// R4 at the finish line: the engine reaches its own `.complete` the moment the last transfer
    /// mines per its tables — one privacy-window before the wallet has synced it. "Migration
    /// complete" over a timeline still showing "Confirming…" is the contradiction R4 forbids, so
    /// the banner holds the counts story until every chain-side row is wallet-confirmed.
    @Test func completeStateHoldsTheCountsStoryWhileARowIsConfirming() {
        let variant = Self.variant(
            state: .complete,
            transferRows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .confirming)
            ]
        )
        #expect(variant == .inProgress(done: 1, total: 2, round: nil, totalRounds: nil))
    }

    /// And the moment the last row is wallet-confirmed, `.complete` renders — the gate holds the
    /// banner back one privacy-window, it does not eat the completion.
    @Test func completeRendersOnceEveryRowIsWalletConfirmed() {
        let variant = Self.variant(
            state: .complete,
            transferRows: [
                Self.row(index: 0, status: .sent),
                Self.row(index: 1, status: .sent)
            ]
        )
        #expect(variant == .complete)
    }

    // MARK: - E. Cross-surface: one count, printed twice (R5)

    /// Contradiction-suite style: the Prepare Balance sheet and the banner read the SAME rows, and
    /// a `.confirming` row must tell the same story through one disclosure tap — Andrea's ladder
    /// word for the on-chain span (`.sent`, "Sent", neutral check), never `.done` with its green
    /// check and never `.preparing` (a word that claims the APP is working while the chain is).
    /// And the banner's done-count is literally `rows.filter { .sent }.count` — the identical
    /// filter both surfaces derive from, so they cannot disagree by construction.
    @Test func theSheetAndTheBannerAgreeOnWhatConfirmingMeans() {
        let rows = [
            Self.row(index: 0, status: .sent, kind: .splitBalance),
            Self.row(index: 1, status: .confirming, kind: .splitBalance),
            Self.row(index: 2, status: .sent, kind: .splitBalance),
            Self.row(index: 3, status: .active, kind: .splitBalance)
        ]
        let sentCount = rows.filter { $0.status == .sent }.count

        // The sheet's mapping: the confirming step is exactly `.sent` — Andrea's word for the
        // on-chain span — which is by construction neither `.done` nor `.preparing`.
        let steps = MigrationPrepareBalanceRow.from(preparations: rows)
        #expect(steps[1].state == .sent)
        #expect(steps.filter { $0.state == .done }.count == sentCount)

        // The banner's count over the SAME array: done == the same filter, and the whole variant
        // is exact — 2 of 4, with the confirming row in neither number's green column. Re-anchored
        // onto `.preparing` for the ratified idle (2026-08-06): the `.active` row is marked
        // in-flight so the counts-rendering arm fires; a nothing-in-flight fixture now renders
        // `.idle`, which carries no counts to agree or disagree.
        let inFlightRows = rows.enumerated().map { index, row in
            index == 3 ? Self.row(index: 3, status: .active, kind: .splitBalance, isPreparing: true) : row
        }
        let variant = Self.variant(
            state: .inProgress(Self.progress(completed: sentCount, total: inFlightRows.count)),
            transferRows: inFlightRows
        )
        #expect(variant == .preparing(done: sentCount, total: inFlightRows.count))
        #expect(sentCount == 2)
    }

    // MARK: - FIND-1 (2026-08-05, campaign 7): the dependency-blocked row never reads "Overdue"

    /// `hasOverdueMigrationTransfers` is WALLET-WIDE and the engine's overdue set counts
    /// preparation rows too — so a due note-split used to stamp "Overdue · 1 min ago" on
    /// Transfer 1 while the very preparations funding it were still unmined. A row whose own live
    /// status says `blockedOn == .dependencies` is ON PLAN, not late: the aggregate flag must not
    /// put the clock's badge on it.
    @Test func aDependencyBlockedFirstRowIsNeverOverdue() {
        let dependencyBlocked = MigrationTransactionStatus(
            id: 1,
            kind: .transfer(crossing: 0),
            state: .signed,
            scheduledHeight: 2_999_990,
            expiryHeight: nil,
            isReady: false,
            nextAction: nil,
            blockedOn: .dependencies,
            dependsOn: [7],
            anchorBoundaryHeight: nil
        )
        let rows = MigrationDerivations.transferRows(
            committedSchedule: Self.committedSchedule(sentRecords: []),
            state: .inProgress(Self.progress(completed: 0, total: 1)),
            hasOverdueMigrationTransfers: true,
            now: Self.now,
            clock: Self.clock,
            statuses: [dependencyBlocked]
        )

        #expect(rows[0].status == .active, "the aggregate overdue flag must not badge a dependency-blocked row, got \(rows[0].status)")
        #expect(rows[0].isAwaitingRunDependencies, "the dependency truth must ride the row for the caption")
        #expect(rows[0].overdueMinutesAgo == nil)
        #expect(!rows[0].isInFlight, "nothing runs on this device for a dependency-blocked row — no spinner")
    }

    /// The mirror that keeps FIND-1 a veto, not a blanket: the same aggregate flag over a
    /// schedule-blocked first row still reads `.overdue` — the clock's badge is exactly right when
    /// the row itself is what is late.
    @Test func aScheduleBlockedFirstRowStillReadsOverdue() {
        let scheduleBlocked = MigrationTransactionStatus(
            id: 1,
            kind: .transfer(crossing: 0),
            state: .proved,
            scheduledHeight: 2_999_990,
            expiryHeight: nil,
            isReady: false,
            nextAction: nil,
            blockedOn: .schedule,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
        let rows = MigrationDerivations.transferRows(
            committedSchedule: Self.committedSchedule(sentRecords: []),
            state: .inProgress(Self.progress(completed: 0, total: 1)),
            hasOverdueMigrationTransfers: true,
            now: Self.now,
            clock: Self.clock,
            statuses: [scheduleBlocked]
        )

        #expect(rows[0].status == .overdue)
        #expect(!rows[0].isAwaitingRunDependencies)
    }
}
