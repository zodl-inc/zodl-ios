//
//  MigrationArrivedWindowCaptionTests.swift
//  zodlTests
//
//  "Ready now" is not a phase (MOB-1466, Lukas's ruling 2026-08-08).
//
//  THE FIELD REPORT. Lukas opened Zodl after several hours away and found "Ready now" on most of
//  his transfers. The cause was arithmetic, not design: `MigrationChainClock.secondsUntil` returns
//  zero for any height at or behind the tip, `MigrationETA.minutesFromNow` clamps at zero on top of
//  it, and `bucketed` reads `<= 0` as `.readyNow`. A height three hours in the past and one due
//  this second produce the identical `0`. Sleep through part of a schedule and every passed row
//  claims to be actionable.
//
//  It was wrong twice over. Wrong about TIME, because those windows had passed rather than
//  arrived. And wrong about ACTIONABILITY, because ZIP 318 permits one broadcast at a time — the
//  derivation itself only ever makes ONE row the acted-on one (`nonSentRowStatus`'s
//  `guard isFirstNonSent`) — so all but one of those invitations is refused by the engine.
//
//  Checking the frames settled it: "Ready now" appears in no post-commit screen, only the `.replan`
//  and expiry flows. Lukas's statement of the real ladder: a prepared transfer says "~X", a passed
//  one is overdue, "there is no phase at all saying ready now".
//
//  WHY "Recomputing ETA…" IS THE TRUE WORD and not merely a softer one. The engine's overdue
//  re-spread ("at most one overdue transfer is released immediately; the rest are re-spread")
//  raises EVERY pending scheduled height by the lag, judged at the ESTIMATED target so it runs
//  before the wallet syncs (`zcash_pool_migration`, satisfiability.rs). So on the very next
//  `advance_migration` these rows really do get new times. The label states the gap between opening
//  the app and that shift landing — a real interval with a real end.
//
//  THE ONE EXCEPTION, and it is the reason `migrationPlan.readyNow` still exists. The re-spread
//  deliberately excludes an ANCHOR-GATED transfer: re-spreading on one "would shift the whole plan
//  … every time the gate was waited out, chasing its own tail". Nothing will ever recompute that
//  row's height, so "Recomputing ETA…" there would be this same bug pointing the other way. Lukas
//  ruled the fallback rather than new copy — "keep it as 'ready now' (= unblocking you with
//  fallback value rather than some new one)" — so the string survives with exactly one caller.
//

import Foundation
import Testing
@testable import zodl_internal
@preconcurrency import ZcashLightClientKit

@Suite struct MigrationArrivedWindowCaptionTests {
    /// A tip well above every scheduled height below, so "passed" is unambiguous and `isTipKnown`
    /// is true — this suite is about a KNOWN clock, which is exactly what separates it from
    /// `MigrationUnknownTipETATests`.
    private static let tip: BlockHeight = 3_000_000

    private static var clock: MigrationChainClock {
        MigrationChainClock(tip: tip, secondsPerBlock: 75)
    }

    private static func transfer(
        id: UInt32,
        crossing: Int,
        scheduledHeight: BlockHeight,
        blockedOn: MigrationTransactionStatus.Blocker? = MigrationTransactionStatus.Blocker.schedule
    ) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: MigrationTransactionStatus.Kind.transfer(crossing: crossing),
            state: MigrationTransactionStatus.State.signed,
            scheduledHeight: scheduledHeight,
            expiryHeight: nil,
            isReady: false,
            nextAction: nil,
            blockedOn: blockedOn,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    // MARK: - The field report itself

    /// SIX transfers slept through, exactly the shape Lukas photographed. Every one of them has a
    /// passed window, so every one of them used to read "Ready now" — six invitations to act, five
    /// of which the engine refuses. They must now all read "Recomputing ETA…" instead.
    @Test func sixSleptThroughTransfersAllSayRecomputingRatherThanReadyNow() {
        let statuses = (0..<6).map { index in
            Self.transfer(
                id: UInt32(index + 1),
                crossing: index,
                // Every window passed, spread across the hours the wallet was closed.
                scheduledHeight: Self.tip - BlockHeight(600 - index * 100)
            )
        }

        let rows = MigrationDerivations.statusOnlyTransferRows(statuses: statuses, clock: Self.clock) ?? []

        #expect(rows.count == 6)
        for row in rows {
            #expect(row.forwardETAMinutes == 0, "a passed window still clamps to zero — that part is arithmetic, not display")
            #expect(
                MigrationETA.caption(minutesFromNow: row.forwardETAMinutes, phrasing: MigrationETA.Phrasing.bare)
                    == String(localizable: .migrationPlanEtaRecomputing)
            )
        }
    }

    /// The other half of the same screen, and the one that proves this did not simply blank every
    /// caption: a transfer whose window is genuinely AHEAD keeps its real time. Six hours out at 75
    /// s/block is 288 blocks.
    @Test func aFutureWindowStillStatesItsRealTime() {
        let future = Self.transfer(id: 1, crossing: 0, scheduledHeight: Self.tip + 288)

        let rows = MigrationDerivations.statusOnlyTransferRows(statuses: [future], clock: Self.clock)

        #expect(rows?[0].forwardETAMinutes == 360)
        #expect(
            MigrationETA.caption(minutesFromNow: rows?[0].forwardETAMinutes, phrasing: MigrationETA.Phrasing.bare)
                == String(localizable: .migrationPlanEtaHours(6))
        )
    }

    // MARK: - The anchor-gate carve-out

    /// The fact has to RIDE THE ROW for the view's arm to reach it — same discipline as
    /// `isAwaitingRunDependencies`, whose caption arm this one sits beside. W1-fallback lane.
    @Test func anAnchorGatedRowCarriesItsGateIntoTheRow() {
        let gated = Self.transfer(
            id: 1,
            crossing: 0,
            scheduledHeight: Self.tip - 200,
            blockedOn: MigrationTransactionStatus.Blocker.anchorBoundary
        )

        let rows = MigrationDerivations.statusOnlyTransferRows(statuses: [gated], clock: Self.clock)

        #expect(rows?[0].isAwaitingAnchorBoundary == true, "the anchor gate must ride the row — the caption arm reads it")
        #expect(rows?[0].forwardETAMinutes == 0, "its window has passed like any other; only the REMEDY differs")
    }

    /// And the mirror, so the carve-out stays a carve-out: an ordinary schedule-blocked row with an
    /// equally passed window does NOT claim the anchor gate, and therefore does not keep "Ready
    /// now". If this ever flips true the exception has swallowed the rule.
    @Test func anOrdinarySleptThroughRowDoesNotClaimTheAnchorGate() {
        let ordinary = Self.transfer(id: 1, crossing: 0, scheduledHeight: Self.tip - 200)

        let rows = MigrationDerivations.statusOnlyTransferRows(statuses: [ordinary], clock: Self.clock)

        #expect(rows?[0].isAwaitingAnchorBoundary == false)
    }

    /// `migrationPlan.readyNow` must SURVIVE in the catalogue. It is no longer the default answer
    /// for a passed row, but the anchor-gated arm renders it, and a catalogue cleanup that removed
    /// it as "unused" would break that arm silently — the accessor is generated, so the failure
    /// would be a build error at best and a wrong string at worst.
    @Test func theReadyNowStringSurvivesForItsOneRemainingCaller() {
        #expect(String(localizable: .migrationPlanReadyNow) == "Ready now")
    }
}
