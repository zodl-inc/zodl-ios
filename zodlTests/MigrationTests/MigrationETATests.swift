//
//  MigrationETATests.swift
//  zodlTests
//
//  Covers the central forward-ETA helper (Utils/MigrationETA.swift) for MOB-1513 (B3): the
//  block-delta minutes math (`(scheduledHeight − currentTip) × 75s`, floored, with an unknown/low
//  tip fail-safe), the minute/hour granularity buckets, and the localized caption shapes for both
//  phrasings (Transfer Plan scheduled = "in ~…", every other forward surface = bare "~…"). No
//  shared/global state -> no `.serialized`.
//

import Testing
import Foundation
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationETATests {
    // MARK: - minutesFromNow: block-delta math at 75 s/block

    @Test func minutesFromNowIsBlockDeltaAt75SecondsPerBlock() {
        // 96 blocks × 75 s = 7200 s = 120 min
        #expect(MigrationETA.minutesFromNow(scheduledHeight: 1_096, currentTip: 1_000) == 120)
        // 48 blocks × 75 s = 3600 s = 60 min
        #expect(MigrationETA.minutesFromNow(scheduledHeight: 1_048, currentTip: 1_000) == 60)
        // 40 blocks × 75 s = 3000 s = 50 min
        #expect(MigrationETA.minutesFromNow(scheduledHeight: 1_040, currentTip: 1_000) == 50)
    }

    @Test func minutesFromNowFloorsPartialMinutes() {
        // 1 block × 75 s = 75 s = 1.25 min -> floor 1
        #expect(MigrationETA.minutesFromNow(scheduledHeight: 1_001, currentTip: 1_000) == 1)
    }

    @Test func minutesFromNowIsZeroWhenHeightAtOrBelowTip() {
        #expect(MigrationETA.minutesFromNow(scheduledHeight: 1_000, currentTip: 1_000) == 0)
        #expect(MigrationETA.minutesFromNow(scheduledHeight: 900, currentTip: 1_000) == 0)
    }

    @Test func minutesFromNowIsZeroWhenTipUnknown() {
        // Fail-safe sentinel: an unknown tip (0, before the first server round-trip) is not a low
        // one, so it must not be subtracted from (mirrors isIronwoodActivated/liveStalledHoursAgo).
        #expect(MigrationETA.minutesFromNow(scheduledHeight: 5_000, currentTip: 0) == 0)
    }

    // MARK: - bucketed: granularity boundaries (0 / 59 / 60 / 61)

    @Test func bucketedZeroOrNegativeIsReadyNow() {
        #expect(MigrationETA.bucketed(minutesFromNow: 0) == .readyNow)
        #expect(MigrationETA.bucketed(minutesFromNow: -5) == .readyNow)
    }

    @Test func bucketedUnderOneHourIsMinutes() {
        #expect(MigrationETA.bucketed(minutesFromNow: 1) == .minutes(1))
        #expect(MigrationETA.bucketed(minutesFromNow: 59) == .minutes(59))
    }

    @Test func bucketedOneHourAndAboveIsHoursFloored() {
        #expect(MigrationETA.bucketed(minutesFromNow: 60) == .hours(1))
        #expect(MigrationETA.bucketed(minutesFromNow: 61) == .hours(1))
        #expect(MigrationETA.bucketed(minutesFromNow: 120) == .hours(2))
        #expect(MigrationETA.bucketed(minutesFromNow: 155) == .hours(2))
    }

    // MARK: - caption shapes across the three forward surfaces

    /// Surface 1 — Transfer Plan scheduled: the "in ~…" phrasing.
    @Test func captionInPrefixedRendersReadyNowMinutesAndHours() {
        #expect(MigrationETA.caption(minutesFromNow: 0, phrasing: .inPrefixed) == String(localizable: .migrationPlanReadyNow))
        #expect(MigrationETA.caption(minutesFromNow: 5, phrasing: .inPrefixed) == String(localizable: .migrationPlanEtaMinsIn(5)))
        #expect(MigrationETA.caption(minutesFromNow: 120, phrasing: .inPrefixed) == String(localizable: .migrationPlanEtaHoursIn(2)))
    }

    /// Surfaces 2 & 3 — Transfer Plan manual/recreated + Status/Progress/Resume: the bare "~…"
    /// phrasing.
    @Test func captionBareRendersReadyNowMinutesAndHours() {
        #expect(MigrationETA.caption(minutesFromNow: 0, phrasing: .bare) == String(localizable: .migrationPlanReadyNow))
        #expect(MigrationETA.caption(minutesFromNow: 30, phrasing: .bare) == String(localizable: .migrationPlanEtaMins(30)))
        #expect(MigrationETA.caption(minutesFromNow: 360, phrasing: .bare) == String(localizable: .migrationPlanEtaHours(6)))
    }

    // MARK: - Status/Progress + Resume surface: coarse whole-hour rows (no minutesFromNow)

    /// The synthetic-cadence surfaces (Status/Progress, Resume) carry only `hoursFromNow` — the
    /// caption reads it through `MigrationTransferRow.forwardETAMinutes` (nil `minutesFromNow` ->
    /// hours × 60), so a 6-hour pending row reads "~6 hours" and a ready-now (0-hour) row reads
    /// "Ready now" (never the retired "~10 mins" fallback).
    @Test func coarseHourRowsCaptionThroughForwardETAMinutesFallback() {
        let pending = MigrationTransferRow(id: "p", index: 3, amount: Zatoshi(1), status: .pending, hoursFromNow: 6)
        #expect(pending.minutesFromNow == nil)
        #expect(pending.forwardETAMinutes == 360)
        #expect(MigrationETA.caption(minutesFromNow: pending.forwardETAMinutes, phrasing: .bare) == String(localizable: .migrationPlanEtaHours(6)))

        let readyNow = MigrationTransferRow(id: "a", index: 0, amount: Zatoshi(1), status: .active, hoursFromNow: 0)
        #expect(readyNow.forwardETAMinutes == 0)
        #expect(MigrationETA.caption(minutesFromNow: readyNow.forwardETAMinutes, phrasing: .bare) == String(localizable: .migrationPlanReadyNow))
    }

    /// A minute-precise row (Transfer Plan) prefers `minutesFromNow` over the coarse `hoursFromNow`.
    @Test func forwardETAMinutesPrefersTheMinutePreciseValueWhenPresent() {
        let row = MigrationTransferRow(id: "t", index: 1, amount: Zatoshi(1), status: .pending, hoursFromNow: 0, minutesFromNow: 45)
        #expect(row.forwardETAMinutes == 45)
        #expect(MigrationETA.caption(minutesFromNow: row.forwardETAMinutes, phrasing: .inPrefixed) == String(localizable: .migrationPlanEtaMinsIn(45)))
    }

    /// Red-first (B3 symptom): a future-height row rendered the "~10 mins" fallback
    /// (`migrationPlanEtaFirst`) today because `estimateTimestamp` returns nil for heights beyond the
    /// newest bundled checkpoint; the block-delta helper reads a real "in ~2 hours" instead.
    @Test func futureHeightRowReadsRealHoursNotTheTenMinsFallback() {
        let minutes = MigrationETA.minutesFromNow(scheduledHeight: 1_096, currentTip: 1_000)
        let caption = MigrationETA.caption(minutesFromNow: minutes, phrasing: .inPrefixed)

        // "in ~2 hours" — never the retired "~10 mins" fallback the pre-B3 code rendered here.
        #expect(caption == String(localizable: .migrationPlanEtaHoursIn(2)))
    }
}
