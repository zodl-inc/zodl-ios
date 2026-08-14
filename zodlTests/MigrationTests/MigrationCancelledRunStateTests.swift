//
//  MigrationCancelledRunStateTests.swift
//  zodlTests
//
//  A run the USER cancelled reads as no-run, so the banner re-offers migration (MOB-1466,
//  Lukas 2026-08-07: "we need to start over and let it find orchard funds from the beginning").
//
//  THE FIELD REPORT: "I restarted the migration and saw update migration plan instead of migration
//  required."
//
//  WHY THE APP HAS TO CARRY THIS. `zcashlc_migration_restart_step` calls the engine's
//  `cancel_migration()`, and the SDK folds cancelled into the same terminal step as every other
//  ending — "`complete` is terminal for the STORED run — including a CANCELLED one". So
//  `advanceStep`/`progress`/`statuses`/`hasInvalidTransfers` cannot tell "the user asked to start
//  over" from "this run died unfinished", and M1's terminated-unfinished rule read the cancellation
//  as `.requiresAttention(.invalidTransfer)` -> the `.updatePlan` banner.
//
//  THE RISK IS FALSE POSITIVES, and Lukas named it: "migration complete must be protected.. we
//  really only want to show migration required when I used restart migration in the advanced
//  settings." Every test below exists to bound this flag rather than to exercise it.
//

import Foundation
import Testing
@_spi(Testing) import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationCancelledRunStateTests {
    private static func transferStatus(id: UInt32, state: MigrationTransactionStatus.State) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: .transfer(crossing: Int(id)),
            state: state,
            scheduledHeight: 4_243_400,
            expiryHeight: nil,
            isReady: false,
            nextAction: nil,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    /// THE FIX. Lukas's own shape: 2 of 11 mined, the rest abandoned by an explicit restart.
    /// Terminated unfinished AND cancelled by the user ⇒ no run, so `.required` falls out of the
    /// banner derivation from the remaining Orchard.
    @Test func aUserCancelledUnfinishedRunReadsAsNotStarted() {
        let statuses = [
            Self.transferStatus(id: 0, state: .mined(height: 4_243_100)),
            Self.transferStatus(id: 1, state: .mined(height: 4_243_200)),
            Self.transferStatus(id: 2, state: .signed)
        ]

        let state = MigrationState.derive(
            advanceStep: .complete,
            progress: nil,
            statuses: statuses,
            hasInvalidTransfers: false,
            wasCancelledByUser: true
        )

        #expect(state == .notStarted)
    }

    /// THE GUARD THAT MATTERS MOST. The SAME unfinished shape WITHOUT the flag still routes to the
    /// attention lane — a run that merely died is untouched by this change. If this ever flips,
    /// every failed run silently starts pretending it was never there.
    @Test func anUnfinishedRunNobodyCancelledStillRequiresAttention() {
        let statuses = [
            Self.transferStatus(id: 0, state: .mined(height: 4_243_100)),
            Self.transferStatus(id: 1, state: .signed)
        ]

        let state = MigrationState.derive(
            advanceStep: .complete,
            progress: nil,
            statuses: statuses,
            hasInvalidTransfers: false
        )

        #expect(state == .requiresAttention(.invalidTransfer))
    }

    /// MIGRATION COMPLETE IS PROTECTED (Lukas's explicit constraint). Every transfer mined ⇒
    /// `.complete`, and the flag is not even consulted on that path — so no marker, stale or
    /// otherwise, can turn a finished migration back into an offer.
    @Test func aFullyMinedRunIsCompleteEvenWithTheFlagSet() {
        let statuses = [
            Self.transferStatus(id: 0, state: .mined(height: 4_243_100)),
            Self.transferStatus(id: 1, state: .mined(height: 4_243_200))
        ]

        #expect(
            MigrationState.derive(
                advanceStep: .complete,
                progress: nil,
                statuses: statuses,
                hasInvalidTransfers: false,
                wasCancelledByUser: true
            ) == .complete
        )
    }

    /// Empty statuses stay `.complete` too — a finished-and-cleared run reads no differently than
    /// before, flag or no flag.
    @Test func aClearedRunIsCompleteEvenWithTheFlagSet() {
        #expect(
            MigrationState.derive(
                advanceStep: .complete,
                progress: nil,
                statuses: [],
                hasInvalidTransfers: false,
                wasCancelledByUser: true
            ) == .complete
        )
    }

    /// The flag never reaches a LIVE run. `hasInvalidTransfers` and the engine's own
    /// `.replan` both answer ahead of the terminal arm, and a driving step never gets
    /// there at all — so a marker that somehow outlived its run cannot hijack an active migration.
    @Test func theFlagCannotAffectALiveRun() {
        #expect(
            MigrationState.derive(
                advanceStep: .broadcast(MigrationBroadcastInstruction(id: 3)),
                progress: nil,
                statuses: [],
                hasInvalidTransfers: false,
                wasCancelledByUser: true
            ) != .notStarted
        )
        #expect(
            MigrationState.derive(
                advanceStep: .replan,
                progress: nil,
                statuses: [],
                hasInvalidTransfers: false,
                wasCancelledByUser: true
            ) == .requiresAttention(.invalidTransfer)
        )
        #expect(
            MigrationState.derive(
                advanceStep: .rebuild(id: 3),
                progress: nil,
                statuses: [],
                hasInvalidTransfers: true,
                wasCancelledByUser: true
            ) == .requiresAttention(.invalidTransfer)
        )
    }

    /// The default keeps every existing caller and pin behaving exactly as before — this parameter
    /// can only ADD a path.
    @Test func theFlagDefaultsToFalse() {
        let statuses = [Self.transferStatus(id: 0, state: .signed)]

        #expect(
            MigrationState.derive(advanceStep: .complete, progress: nil, statuses: statuses, hasInvalidTransfers: false)
                == .requiresAttention(.invalidTransfer)
        )
    }

    /// THE MARKER'S LIFETIME, pinned on the payload rather than described in prose: committing a
    /// new plan REPLACES the payload the flag lives in, so the next run starts clean without a
    /// clearing step anyone could forget to call.
    @Test func committingANewPlanDropsTheMarker() {
        var payload = MigrationCommittedSchedule(
            schedule: MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 1, preparations: []),
            sentRecords: [],
            committedAt: Date(timeIntervalSince1970: 0)
        )
        payload.cancelledByUserAt = Date(timeIntervalSince1970: 100)
        #expect(payload.cancelledByUserAt != nil)

        // What `recordCommittedSchedule` does: a fresh payload carrying only the sent records.
        let recommitted = MigrationCommittedSchedule(
            schedule: MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 1, preparations: []),
            sentRecords: payload.sentRecords,
            committedAt: Date(timeIntervalSince1970: 200)
        )

        #expect(recommitted.cancelledByUserAt == nil, "a newly committed plan is a new run and inherits no cancellation")
    }
}
