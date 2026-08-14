//
//  MigrationChainClockTests.swift
//  zodlTests
//
//  Covers `MigrationChainClock` and `MigrationETA.minutesFromNow`'s new frame — P3's replacement for
//  "scanned tip at a hardcoded 75 s".
//
//  Two of these pin behaviour that only looks like an implementation detail. The unknown-tip floor
//  is a fail-safe: a tip of 0 means "the wallet has never scanned", and subtracting from it would
//  turn every migration height into a distance of years. And the rate is what makes an ETA an
//  ETA — at the extremes of the SDK's own clamp the SAME block delta is thirty times apart, so a
//  screen built on the target rate is not approximately right, it is a different answer.
//

import Foundation
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationChainClockTests {
    // MARK: - The frame

    @Test func aFutureHeightIsItsBlockDeltaAtTheMeasuredRate() {
        let clock = MigrationChainClock(tip: 1000, secondsPerBlock: 60)
        #expect(clock.secondsUntil(height: 1040) == 2400)
    }

    @Test(arguments: [1000, 999, 0]) func aHeightAtOrBehindTheTipIsNow(height: BlockHeight) {
        #expect(MigrationChainClock(tip: 1000).secondsUntil(height: height) == 0)
    }

    /// The fail-safe: an unknown tip is not a low one. Measuring against it would report every
    /// migration height as being years away instead of "Ready now".
    @Test func anUnknownTipFloorsEverythingToNow() {
        #expect(MigrationChainClock.unknown.secondsUntil(height: 5_000_000) == 0)
    }

    /// A hand-built clock cannot smuggle in a rate that would make every future height read as
    /// "now" (zero) or as infinitely far away (negative).
    @Test(arguments: [0.0, -30.0]) func aNonPositiveRateFallsBackToTargetSpacing(rate: Double) {
        #expect(MigrationChainClock(tip: 1000, secondsPerBlock: rate).secondsPerBlock == MigrationChainClock.targetSecondsPerBlock)
    }

    @Test func dateAtHeightIsNowPlusTheDistance() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = MigrationChainClock(tip: 100, secondsPerBlock: 75)
        #expect(clock.date(atHeight: 180, now: now) == now.addingTimeInterval(6000))
    }

    // MARK: - What the measured rate actually buys

    /// The reason the rate is read rather than assumed. The SDK clamps its measurement to [5, 150] s;
    /// across that range one block delta spans half an hour to a full day.
    @Test func theSameDeltaIsHoursApartAtDifferentRates() {
        let delta: BlockHeight = 480
        let fast = MigrationChainClock(tip: 0 + 1, secondsPerBlock: 5)
        let slow = MigrationChainClock(tip: 0 + 1, secondsPerBlock: 150)

        #expect(MigrationETA.minutesFromNow(scheduledHeight: 1 + delta, clock: fast) == 40)
        #expect(MigrationETA.minutesFromNow(scheduledHeight: 1 + delta, clock: slow) == 1200)
    }

    /// Default construction is the pre-P3 behaviour exactly — Zcash's target spacing — so a clock
    /// built without a measurement is never worse than what it replaced.
    @Test func theDefaultRateIsTargetSpacing() {
        let clock = MigrationChainClock(tip: 1000)
        #expect(clock.secondsPerBlock == 75.0)
        #expect(MigrationETA.minutesFromNow(scheduledHeight: 1048, clock: clock) == 60)
    }

    // MARK: - The notification buffer

    /// Two blocks at target spacing IS 150 s, so on a healthy chain both readings of "add two
    /// blocks" agree.
    @Test func theBufferIsTwoBlocksAtTargetSpacing() {
        #expect(MigrationChainClock(tip: 1000).notificationBuffer == 150)
    }

    /// A slow chain gets two REAL blocks, not two nominal ones — the whole point of a block-denominated
    /// buffer.
    @Test func aSlowChainGetsTwoRealBlocks() {
        #expect(MigrationChainClock(tip: 1000, secondsPerBlock: 150).notificationBuffer == 300)
    }

    /// A fast chain keeps the 150 s floor. Two blocks at 5 s is 10 s of slack, which is no slack at
    /// all against estimator error — and firing early is the failure mode that costs the user
    /// something.
    @Test func aFastChainKeepsTheFloor() {
        #expect(MigrationChainClock(tip: 1000, secondsPerBlock: 5).notificationBuffer == 150)
    }

    @Test func aNotificationLandsAfterTheHeightItNames() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = MigrationChainClock(tip: 100, secondsPerBlock: 75)
        let height: BlockHeight = 180

        #expect(clock.notificationDate(atHeight: height, now: now) == clock.date(atHeight: height, now: now).addingTimeInterval(150))
    }

    /// Even a height already at the tip is poked about slightly late rather than instantly — the
    /// estimate that produced "now" is itself approximate.
    @Test func aDueHeightIsStillBuffered() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(MigrationChainClock(tip: 1000).notificationDate(atHeight: 900, now: now) == now.addingTimeInterval(150))
    }

    // MARK: - Bucketing through the frame

    @Test func minutesFloorRatherThanRound() {
        // 1 block at 75 s is 1.25 minutes — one minute, not two.
        let clock = MigrationChainClock(tip: 1000)
        #expect(MigrationETA.minutesFromNow(scheduledHeight: 1001, clock: clock) == 1)
    }

    @Test func aSubMinuteDistanceReadsAsReadyNow() {
        let clock = MigrationChainClock(tip: 1000, secondsPerBlock: 5)
        #expect(MigrationETA.minutesFromNow(scheduledHeight: 1005, clock: clock) == 0)
        #expect(MigrationETA.bucketed(minutesFromNow: 0) == .readyNow)
    }
}
