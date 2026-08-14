//
//  MigrationUnknownTipETATests.swift
//  zodlTests
//
//  An unknown chain tip must never render as "Ready now" (MOB-1466, Lukas 2026-08-07).
//
//  THE FIELD BUG. On a cold launch the migration trace prints `APP OPEN … tip 0` — the tip is not
//  known yet. `MigrationChainClock.secondsUntil` returns 0 for that (correct arithmetic: an unknown
//  tip must not be subtracted from), `minutesFromNow` floored it to 0, and `bucketed` reads `<= 0`
//  as `.readyNow`. Result: ELEVEN pending transfers all told the user to act, for the few seconds
//  until the tip landed and they flipped to their real times.
//
//  The arithmetic was never wrong. The DISPLAY collapse was: zero meant two different things, and
//  the more alarming one won. Lukas's rule: "either we know Tx send height => ETAs or we don't.. if
//  we don't we need to write 'recomputing ETA...'".
//

import Foundation
import Testing
@testable import zodl_internal

@Suite struct MigrationUnknownTipETATests {
    /// THE REGRESSION ITSELF. `.unknown` is the cold-launch clock; a height far in the future must
    /// produce no answer rather than "now".
    @Test func unknownTipYieldsNoETA() {
        let eta = MigrationETA.minutesFromNow(scheduledHeight: 4_243_475, clock: .unknown)

        #expect(eta == nil, "an unknown tip must not answer with a number")
        #expect(!MigrationChainClock.unknown.isTipKnown)
    }

    /// The other half of the distinction: with a KNOWN tip, a height at or behind it is genuinely
    /// ready and still reads 0. If this ever returns nil the fix has overreached and real
    /// ready-now rows would start claiming to be recomputing.
    @Test func knownTipStillAnswersZeroForAPassedHeight() {
        let clock = MigrationChainClock(tip: 4_243_500)

        #expect(MigrationETA.minutesFromNow(scheduledHeight: 4_243_400, clock: clock) == 0)
        #expect(MigrationETA.minutesFromNow(scheduledHeight: 4_243_500, clock: clock) == 0)
        #expect(clock.isTipKnown)
    }

    /// A known tip and a future height: the ordinary path, unchanged.
    @Test func knownTipMeasuresForwardNormally() {
        let clock = MigrationChainClock(tip: 4_243_400, secondsPerBlock: 60)

        #expect(MigrationETA.minutesFromNow(scheduledHeight: 4_243_410, clock: clock) == 10)
    }

    /// THE CAPTION, which is what the user actually saw. `nil` says "Recomputing ETA…" in every
    /// phrasing — no surface may fall back to a number it does not have.
    @Test func noETACaptionsAsRecomputingInEveryPhrasing() {
        let recomputing = String(localizable: .migrationPlanEtaRecomputing)

        for phrasing in [MigrationETA.Phrasing.plan, .bare, .inPrefixed] {
            #expect(MigrationETA.caption(minutesFromNow: nil, phrasing: phrasing) == recomputing)
        }
    }

    /// The PRE-COMMIT screen still says "Starts right away" for a real zero — that string is a
    /// designed frame in its own committal tense (see `MigrationETA.Phrasing.plan`), and the
    /// 2026-08-08 ruling that retired "Ready now" from the post-commit surfaces deliberately did
    /// not touch it. If this ever flips to "Recomputing ETA…", the Transfer Plan screen has started
    /// telling a user who has not yet confirmed anything that a calculation is under way.
    @Test func planZeroStillStartsRightAway() {
        #expect(
            MigrationETA.caption(minutesFromNow: 0, phrasing: .plan)
                == String(localizable: .migrationPlanStartsRightAway)
        )
    }

    /// A row built without a tip carries no ETA at all — `forwardETAMinutes` refuses rather than
    /// falling through to `hoursFromNow`, which on this path was derived from the same blank clock.
    @Test func rowWithUnknownETAAnswersNil() {
        let row = MigrationTransferRow(
            id: "1",
            index: 0,
            amount: nil,
            status: .active,
            hoursFromNow: 0,
            minutesFromNow: nil,
            isETAKnown: false
        )

        #expect(row.forwardETAMinutes == nil)
    }

    /// The default stays `true`, so every construction site that predates this — including
    /// `synthesizedTransferRows`, whose `hoursFromNow` is a position-based cadence estimate that
    /// never consults a tip — keeps answering exactly as before.
    @Test func rowsAreETAKnownByDefault() {
        let row = MigrationTransferRow(id: "1", index: 0, amount: nil, status: .pending, hoursFromNow: 6)

        #expect(row.isETAKnown)
        #expect(row.forwardETAMinutes == 360)
    }

    /// FINISHED ROWS STAY SILENT (Lukas's ruling: "finished rows are silent, they have green
    /// checkmark and DONE label"). The prepare row splits the two questions — is there a forward
    /// statement at all, and if so how long — precisely so a completed step never starts announcing
    /// "Recomputing ETA…" under its own check.
    @Test func finishedPrepareRowsHaveNoForwardTimeAtAll() {
        let done = MigrationPrepareBalanceRow(id: "0", index: 0, state: .done, hasForwardTime: false, minutesFromNow: nil)
        let pendingUnknown = MigrationPrepareBalanceRow(id: "1", index: 1, state: .scheduled, hasForwardTime: true, minutesFromNow: nil)

        #expect(!done.hasForwardTime, "a finished step says nothing, not 'recomputing'")
        #expect(pendingUnknown.hasForwardTime, "a pending step with no tip still owes the user a line")
        #expect(pendingUnknown.minutesFromNow == nil)
    }
}
