//
//  MigrationCadenceTests.swift
//  zodlTests
//
//  Covers `MigrationCadence` (Dependencies/MigrationBGScheduler/MigrationCadence.swift) for
//  MOB-1467: the margin constants (§8.3: 30 min / 6.5 h) and the `window(margin:
//  preferredExecutableAt:now:)` max rule — the SDK's preferred executable time wins when it is
//  later than the margin floor, the margin floor wins when the SDK preference is earlier (or
//  nil, as against the current stubs). Pure math, no shared state -> no `.serialized`.
//
//  `preferredExecutableAt`/`window` inputs and expectations are expressed relative to a fixed
//  `now` so every row is self-contained and doesn't depend on wall-clock time.
//

import Testing
import Foundation
@testable import zodl_internal

@Suite struct MigrationCadenceTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Margin constants

    @Test func firstWindowMarginIsThirtyMinutes() {
        #expect(MigrationCadence.firstWindowMargin == 30 * 60)
    }

    @Test func nextWindowMarginIsSixAndAHalfHours() {
        #expect(MigrationCadence.nextWindowMargin == 6.5 * 60 * 60)
    }

    // MARK: - window(margin:preferredExecutableAt:now:) — max rule

    @Test func nilPreferredFallsBackToMarginFloorForFirstWindow() {
        let window = MigrationCadence.window(
            margin: MigrationCadence.firstWindowMargin,
            preferredExecutableAt: nil,
            now: Self.now
        )

        #expect(window == Self.now.addingTimeInterval(MigrationCadence.firstWindowMargin))
    }

    @Test func nilPreferredFallsBackToMarginFloorForNextWindow() {
        let window = MigrationCadence.window(
            margin: MigrationCadence.nextWindowMargin,
            preferredExecutableAt: nil,
            now: Self.now
        )

        #expect(window == Self.now.addingTimeInterval(MigrationCadence.nextWindowMargin))
    }

    @Test func preferredLaterThanMarginFloorWins() {
        // SDK preference (2 hours out) is later than the 30-minute margin floor -> SDK wins.
        let preferred = Self.now.addingTimeInterval(2 * 60 * 60)

        let window = MigrationCadence.window(
            margin: MigrationCadence.firstWindowMargin,
            preferredExecutableAt: preferred,
            now: Self.now
        )

        #expect(window == preferred)
    }

    @Test func preferredEarlierThanMarginFloorFallsBackToMargin() {
        // SDK preference (10 minutes out) is earlier than the 30-minute margin floor -> margin wins.
        let preferred = Self.now.addingTimeInterval(10 * 60)

        let window = MigrationCadence.window(
            margin: MigrationCadence.firstWindowMargin,
            preferredExecutableAt: preferred,
            now: Self.now
        )

        #expect(window == Self.now.addingTimeInterval(MigrationCadence.firstWindowMargin))
    }

    @Test func preferredExactlyAtMarginFloorUsesThatMoment() {
        // Boundary: preferred == margin floor exactly -> `max` picks either (they're equal).
        let preferred = Self.now.addingTimeInterval(MigrationCadence.firstWindowMargin)

        let window = MigrationCadence.window(
            margin: MigrationCadence.firstWindowMargin,
            preferredExecutableAt: preferred,
            now: Self.now
        )

        #expect(window == preferred)
    }

    @Test func preferredInThePastFallsBackToMargin() {
        // A stale/past SDK preference must never win over the margin floor (never wake "now").
        let preferred = Self.now.addingTimeInterval(-3600)

        let window = MigrationCadence.window(
            margin: MigrationCadence.nextWindowMargin,
            preferredExecutableAt: preferred,
            now: Self.now
        )

        #expect(window == Self.now.addingTimeInterval(MigrationCadence.nextWindowMargin))
    }

    @Test func preferredLaterThanNextWindowMarginWins() {
        // SDK preference (7 hours out) is later than the 6.5-hour next-window margin -> SDK wins.
        let preferred = Self.now.addingTimeInterval(7 * 60 * 60)

        let window = MigrationCadence.window(
            margin: MigrationCadence.nextWindowMargin,
            preferredExecutableAt: preferred,
            now: Self.now
        )

        #expect(window == preferred)
    }

    // MARK: - Full table (both margins x nil/earlier/later), one assertion per row

    @Test func windowTable() {
        struct Row {
            let name: String
            let margin: TimeInterval
            let preferredOffset: TimeInterval?   // relative to `now`; nil = no SDK preference
            let expectedOffset: TimeInterval      // relative to `now`
        }

        let rows: [Row] = [
            Row(
                name: "first/nil",
                margin: MigrationCadence.firstWindowMargin,
                preferredOffset: nil,
                expectedOffset: MigrationCadence.firstWindowMargin
            ),
            Row(
                name: "first/earlier",
                margin: MigrationCadence.firstWindowMargin,
                preferredOffset: 60,
                expectedOffset: MigrationCadence.firstWindowMargin
            ),
            Row(
                name: "first/later",
                margin: MigrationCadence.firstWindowMargin,
                preferredOffset: 3600,
                expectedOffset: 3600
            ),
            Row(
                name: "next/nil",
                margin: MigrationCadence.nextWindowMargin,
                preferredOffset: nil,
                expectedOffset: MigrationCadence.nextWindowMargin
            ),
            Row(
                name: "next/earlier",
                margin: MigrationCadence.nextWindowMargin,
                preferredOffset: 3600,
                expectedOffset: MigrationCadence.nextWindowMargin
            ),
            Row(
                name: "next/later",
                margin: MigrationCadence.nextWindowMargin,
                preferredOffset: 8 * 60 * 60,
                expectedOffset: 8 * 60 * 60
            )
        ]

        for row in rows {
            let preferred = row.preferredOffset.map { Self.now.addingTimeInterval($0) }
            let window = MigrationCadence.window(margin: row.margin, preferredExecutableAt: preferred, now: Self.now)
            let expected = Self.now.addingTimeInterval(row.expectedOffset)

            #expect(window == expected, "Row \(row.name) expected \(expected) but got \(window)")
        }
    }
}
