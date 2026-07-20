//
//  MigrationCadenceTests.swift
//  zodlTests
//
//  Covers `MigrationCadence` (Dependencies/MigrationBGScheduler/MigrationCadence.swift) for
//  MOB-1467: the margin constants (§8.3: 30 min / 6.5 h) and the `window(margin:
//  preferredExecutableAt:now:)` max rule — the SDK's preferred executable time wins when it is
//  later than the margin floor, the margin floor wins when the SDK preference is earlier (or nil,
//  e.g. when `estimateTimestamp` can't resolve the height). Pure math, no shared state -> no
//  `.serialized`.
//
//  `preferredExecutableAt`/`window` inputs and expectations are expressed relative to a fixed
//  `now` so every row is self-contained and doesn't depend on wall-clock time.
//
//  MOB-1496 (W5): also covers `planRearm(_:)`, the multi-account earliest-across-accounts
//  reduction — still pure/no shared state, hence still no `.serialized`.
//

import Testing
import Foundation
@preconcurrency import ZcashLightClientKit
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

    // MARK: - planRearm(_:) — earliest-across-accounts reduction (MOB-1496 W5)

    private static let progress = MigrationProgress(
        completedTransfers: 1,
        totalTransfers: 4,
        remainingOrchard: Zatoshi(1_000),
        nextTransferReadyAtHeight: nil
    )

    @Test func emptyInputHasNoActiveRunAndNoHeight() {
        let plan = MigrationCadence.planRearm([])

        #expect(plan.representativeState == MigrationState.complete)
        #expect(plan.earliestNextExecutableAfterHeight == nil)
        #expect(plan.nextTransferNumber == 1)
    }

    @Test func everyAccountCompleteOrNotStartedHasNoActiveRun() {
        let inputs = [
            MigrationCadence.AccountRearmInput(state: MigrationState.complete, progress: nil, nextExecutableAfterHeight: nil),
            MigrationCadence.AccountRearmInput(state: MigrationState.notStarted, progress: nil, nextExecutableAfterHeight: nil)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.representativeState == MigrationState.complete)
        #expect(plan.earliestNextExecutableAfterHeight == nil)
    }

    /// `.readyToPropose`/`.inProgress`/`.requiresAttention` all count as an active run — proven here
    /// via `.readyToPropose` specifically (no height available yet, but still active).
    @Test func readyToProposeCountsAsActiveEvenWithoutAHeight() {
        let inputs = [
            MigrationCadence.AccountRearmInput(state: MigrationState.readyToPropose, progress: nil, nextExecutableAfterHeight: nil)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.representativeState == MigrationState.readyToPropose)
        #expect(plan.earliestNextExecutableAfterHeight == nil)
    }

    @Test func singleActiveAccountsHeightWins() {
        let inputs = [
            MigrationCadence.AccountRearmInput(state: MigrationState.inProgress(Self.progress), progress: Self.progress, nextExecutableAfterHeight: 500)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.representativeState == MigrationState.inProgress(Self.progress))
        #expect(plan.earliestNextExecutableAfterHeight == 500)
        #expect(plan.nextTransferNumber == Self.progress.completedTransfers + 1)
    }

    @Test func twoActiveAccountsEarliestHeightWinsRegardlessOfInputOrder() {
        let laterProgress = MigrationProgress(completedTransfers: 5, totalTransfers: 9, remainingOrchard: Zatoshi(1), nextTransferReadyAtHeight: nil)
        let earlierProgress = MigrationProgress(completedTransfers: 2, totalTransfers: 9, remainingOrchard: Zatoshi(1), nextTransferReadyAtHeight: nil)

        let inputs = [
            MigrationCadence.AccountRearmInput(state: MigrationState.inProgress(laterProgress), progress: laterProgress, nextExecutableAfterHeight: 900),
            MigrationCadence.AccountRearmInput(state: MigrationState.inProgress(earlierProgress), progress: earlierProgress, nextExecutableAfterHeight: 100)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.earliestNextExecutableAfterHeight == 100)
        #expect(plan.nextTransferNumber == earlierProgress.completedTransfers + 1)
    }

    /// The `nextExecutableAfterHeight` probe value is preferred over `progress
    /// .nextTransferReadyAtHeight` when both are present.
    @Test func probeHeightIsPreferredOverProgressReadyHeightWhenBothPresent() {
        let progressWithReadyHeight = MigrationProgress(
            completedTransfers: 0,
            totalTransfers: 1,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: 777
        )
        let inputs = [
            MigrationCadence.AccountRearmInput(
                state: MigrationState.inProgress(progressWithReadyHeight),
                progress: progressWithReadyHeight,
                nextExecutableAfterHeight: 111
            )
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.earliestNextExecutableAfterHeight == 111)
    }

    /// A nil probe falls back to `progress?.nextTransferReadyAtHeight`.
    @Test func nilProbeFallsBackToProgressReadyHeight() {
        let progressWithReadyHeight = MigrationProgress(
            completedTransfers: 0,
            totalTransfers: 1,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: 42
        )
        let inputs = [
            MigrationCadence.AccountRearmInput(
                state: MigrationState.inProgress(progressWithReadyHeight),
                progress: progressWithReadyHeight,
                nextExecutableAfterHeight: nil
            )
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.earliestNextExecutableAfterHeight == 42)
    }

    /// An active account contributes `hasActiveRun`/`representativeState` even when NEITHER height
    /// source is available (mirrors `readyToProposeCountsAsActiveEvenWithoutAHeight`, but for an
    /// `.inProgress` account with a progress payload carrying no ready height yet).
    @Test func activeAccountWithNeitherHeightSourceStillCountsAsActive() {
        let inputs = [
            MigrationCadence.AccountRearmInput(state: MigrationState.inProgress(Self.progress), progress: Self.progress, nextExecutableAfterHeight: nil)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.representativeState == MigrationState.inProgress(Self.progress))
        #expect(plan.earliestNextExecutableAfterHeight == nil)
    }

    /// One complete account beside one active account: the active account's height/state still
    /// wins — a completed account contributes nothing.
    @Test func completeAccountBesideActiveAccountContributesNothing() {
        let inputs = [
            MigrationCadence.AccountRearmInput(state: MigrationState.complete, progress: nil, nextExecutableAfterHeight: nil),
            MigrationCadence.AccountRearmInput(state: MigrationState.inProgress(Self.progress), progress: Self.progress, nextExecutableAfterHeight: 250)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.representativeState == MigrationState.inProgress(Self.progress))
        #expect(plan.earliestNextExecutableAfterHeight == 250)
    }

    /// R8-T3 (#16): an active account with completed transfers but an unresolvable height on BOTH
    /// sources (nil probe, nil `progress.nextTransferReadyAtHeight`) must still float
    /// `nextTransferNumber` to `completedTransfers + 1` — the pre-PR floor (`git show 1c3ef253 --
    /// Dependencies/MigrationBGScheduler/MigrationCadence.swift`) was an unconditional
    /// `completedTransfers + 1`; the current code only ever assigns `nextTransferNumber` inside the
    /// `guard let height = ... else { continue }` branch, so an unresolvable height leaves it
    /// stranded at the loop's initial `1` regardless of how many transfers already completed. Left
    /// uncaught, the BG-scheduled manual-ready notification reads "Transfer 1 — ready to send"
    /// instead of "Transfer 4 — ready to send".
    @Test func nextTransferNumberFallsBackToCompletedPlusOneWhenHeightUnresolvable() {
        let progressWithNoReadyHeight = MigrationProgress(
            completedTransfers: 3,
            totalTransfers: 9,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: nil
        )
        let inputs = [
            MigrationCadence.AccountRearmInput(
                state: MigrationState.inProgress(progressWithNoReadyHeight),
                progress: progressWithNoReadyHeight,
                nextExecutableAfterHeight: nil
            )
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.representativeState == MigrationState.inProgress(progressWithNoReadyHeight))
        #expect(plan.earliestNextExecutableAfterHeight == nil)
        #expect(plan.nextTransferNumber == 4)
    }
}
