//
//  MigrationInvalidRowTests.swift
//  zodlTests
//
//  A25, resolved — per-row invalid identity, from the row's own status (SDK addendum §3).
//
//  This replaced a guess. Until the engine had a per-transaction `.invalid(reason:)` state, the app
//  put the invalid badge on the FIRST NON-SENT row whenever the run reported an invalidation,
//  because nothing said which transfer was meant. Now something does.
//
//  The precedence pinned here is the SDK's own and it is not arbitrary: CHAIN INCLUSION OUTRANKS AN
//  INVALID VERDICT. An invalid mark is an observed event, recorded at a moment in time; a mined
//  transaction is a fact about the chain. A stale verdict must never shadow a landed transaction,
//  or a user sees "needs attention" against money that already arrived.
//

import Foundation
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationInvalidRowTests {
    // MARK: - Fixtures

    private static let clock = MigrationChainClock(tip: 3_000_000)

    private static func status(
        id: UInt32,
        kind: MigrationTransactionStatus.Kind,
        state: MigrationTransactionStatus.State,
        blockedOn: MigrationTransactionStatus.Blocker? = nil
    ) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: kind,
            state: state,
            scheduledHeight: 3_000_100,
            expiryHeight: nil,
            isReady: false,
            nextAction: nil,
            blockedOn: blockedOn,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    private static func transfer(
        id: UInt32,
        crossing: Int,
        state: MigrationTransactionStatus.State,
        blockedOn: MigrationTransactionStatus.Blocker? = nil
    ) -> MigrationTransactionStatus {
        status(id: id, kind: .transfer(crossing: crossing), state: state, blockedOn: blockedOn)
    }

    // MARK: - Transfer rows

    @Test func anInvalidTransferNamesItself() {
        let statuses = [
            Self.transfer(id: 1, crossing: 0, state: .mined(height: 2_999_000)),
            Self.transfer(id: 2, crossing: 1, state: .invalid(reason: .fundingSpent), blockedOn: .invalid),
            Self.transfer(id: 3, crossing: 2, state: .signed)
        ]
        let rows = MigrationDerivations.statusOnlyTransferRows(statuses: statuses, clock: Self.clock)

        #expect(rows?.count == 3)
        #expect(rows?[1].status == .invalid)
        #expect(rows?[1].id == "2")
    }

    /// The badge lands on the invalid row, NOT on the first non-sent one — which is exactly what
    /// the retired guess would have done here (row index 1 happens to be both, so the fixture
    /// deliberately makes them differ below).
    @Test func theBadgeIsNotOnTheFirstNonSentRow() {
        let statuses = [
            Self.transfer(id: 1, crossing: 0, state: .signed),
            Self.transfer(id: 2, crossing: 1, state: .invalid(reason: .rejectedInvalid), blockedOn: .invalid)
        ]
        let rows = MigrationDerivations.statusOnlyTransferRows(statuses: statuses, clock: Self.clock)

        #expect(rows?[0].status != .invalid, "the first non-sent row is not the invalid one")
        #expect(rows?[1].status == .invalid)
    }

    /// The precedence that protects the user's money: a row the wallet has SEEN MINED reports sent,
    /// whatever an earlier invalid verdict said.
    @Test func chainInclusionOutranksAnInvalidVerdict() {
        let statuses = [Self.transfer(id: 1, crossing: 0, state: .mined(height: 2_999_500))]
        let rows = MigrationDerivations.statusOnlyTransferRows(statuses: statuses, clock: Self.clock)

        #expect(rows?.first?.status == .sent)
    }

    @Test(arguments: [
        MigrationInvalidReason.fundingSpent,
        .rejectedInvalid,
        .rejectedExpired
    ])
    func everyInvalidReasonRendersTheSameRow(reason: MigrationInvalidReason) {
        let statuses = [Self.transfer(id: 1, crossing: 0, state: .invalid(reason: reason), blockedOn: .invalid)]
        let rows = MigrationDerivations.statusOnlyTransferRows(statuses: statuses, clock: Self.clock)

        // The REASON is not surfaced per row — the recovery flow explains it once, at run scope.
        #expect(rows?.first?.status == .invalid)
    }

    // MARK: - Preparation steps

    @Test func anInvalidPreparationSaysSoRatherThanPreparing() {
        let statuses = [
            Self.status(id: 1, kind: .preparation(layer: 0, index: 0), state: .mined(height: 2_999_000)),
            Self.status(id: 2, kind: .preparation(layer: 1, index: 0), state: .invalid(reason: .fundingSpent), blockedOn: .invalid)
        ]
        let steps = MigrationDerivations.prepareBalanceRows(statuses: statuses, clock: Self.clock)

        #expect(steps?[0].state == .done)
        #expect(steps?[1].state == .invalid)
    }

    /// The regression this closes: before the state existed, an invalid preparation fell through to
    /// the catch-all and read "Preparing" — telling the user work was under way on a transaction
    /// that can never mine.
    @Test func theInvalidCaptionIsNotThePreparingCaption() {
        #expect(
            MigrationPrepareBalanceSheet.stateCaption(for: .invalid)
                != MigrationPrepareBalanceSheet.stateCaption(for: .preparing)
        )
        #expect(
            MigrationPrepareBalanceSheet.stateCaption(for: .invalid)
                == String(localizable: .migrationPrepareStateInvalid)
        )
    }
}
