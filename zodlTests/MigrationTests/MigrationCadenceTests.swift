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
@testable @preconcurrency import ZcashLightClientKit
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

    /// R8-T5: every `planRearm` test now needs a concrete `AccountUUID` per input (S4:
    /// `RearmPlan.winnerAccountUUID` tracks which account contributed) — distinct `idByte`s let
    /// multi-account tests assert WHICH account won.
    private static func accountUUID(idByte: UInt8 = 1) -> AccountUUID {
        AccountUUID(id: [UInt8](repeating: idByte, count: 16))
    }

    @Test func emptyInputHasNoActiveRunAndNoHeight() {
        let plan = MigrationCadence.planRearm([])

        #expect(plan.representativeState == MigrationState.complete)
        #expect(plan.earliestNextExecutableAfterHeight == nil)
        #expect(plan.nextTransferNumber == 1)
        #expect(plan.winnerAccountUUID == nil)
    }

    @Test func everyAccountCompleteOrNotStartedHasNoActiveRun() {
        let inputs = [
            MigrationCadence.AccountRearmInput(accountUUID: Self.accountUUID(idByte: 1), state: MigrationState.complete, progress: nil, nextExecutableAfterHeight: nil),
            MigrationCadence.AccountRearmInput(accountUUID: Self.accountUUID(idByte: 2), state: MigrationState.notStarted, progress: nil, nextExecutableAfterHeight: nil)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.representativeState == MigrationState.complete)
        #expect(plan.earliestNextExecutableAfterHeight == nil)
        #expect(plan.winnerAccountUUID == nil)
    }

    /// `.readyToPropose`/`.inProgress`/`.requiresAttention` all count as an active run — proven here
    /// via `.readyToPropose` specifically (no height available yet, but still active).
    @Test func readyToProposeCountsAsActiveEvenWithoutAHeight() {
        let inputs = [
            MigrationCadence.AccountRearmInput(accountUUID: Self.accountUUID(), state: MigrationState.readyToPropose, progress: nil, nextExecutableAfterHeight: nil)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.representativeState == MigrationState.readyToPropose)
        #expect(plan.earliestNextExecutableAfterHeight == nil)
    }

    @Test func singleActiveAccountsHeightWins() {
        let account = Self.accountUUID()
        let inputs = [
            MigrationCadence.AccountRearmInput(accountUUID: account, state: MigrationState.inProgress(Self.progress), progress: Self.progress, nextExecutableAfterHeight: 500)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.representativeState == MigrationState.inProgress(Self.progress))
        #expect(plan.earliestNextExecutableAfterHeight == 500)
        #expect(plan.nextTransferNumber == Self.progress.completedTransfers + 1)
        #expect(plan.winnerAccountUUID == account)
    }

    @Test func twoActiveAccountsEarliestHeightWinsRegardlessOfInputOrder() {
        let laterProgress = MigrationProgress(completedTransfers: 5, totalTransfers: 9, remainingOrchard: Zatoshi(1), nextTransferReadyAtHeight: nil)
        let earlierProgress = MigrationProgress(completedTransfers: 2, totalTransfers: 9, remainingOrchard: Zatoshi(1), nextTransferReadyAtHeight: nil)
        let laterAccount = Self.accountUUID(idByte: 1)
        let earlierAccount = Self.accountUUID(idByte: 2)

        let inputs = [
            MigrationCadence.AccountRearmInput(accountUUID: laterAccount, state: MigrationState.inProgress(laterProgress), progress: laterProgress, nextExecutableAfterHeight: 900),
            MigrationCadence.AccountRearmInput(accountUUID: earlierAccount, state: MigrationState.inProgress(earlierProgress), progress: earlierProgress, nextExecutableAfterHeight: 100)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.earliestNextExecutableAfterHeight == 100)
        #expect(plan.nextTransferNumber == earlierProgress.completedTransfers + 1)
        // R8-T5 (S4): the winner is whichever account the EARLIEST height belongs to (the account
        // reached FIRST in the input order here is the LATER one, proving this isn't just "whoever
        // is iterated last").
        #expect(plan.winnerAccountUUID == earlierAccount)
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
                accountUUID: Self.accountUUID(),
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
                accountUUID: Self.accountUUID(),
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
            MigrationCadence.AccountRearmInput(accountUUID: Self.accountUUID(), state: MigrationState.inProgress(Self.progress), progress: Self.progress, nextExecutableAfterHeight: nil)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.representativeState == MigrationState.inProgress(Self.progress))
        #expect(plan.earliestNextExecutableAfterHeight == nil)
    }

    /// One complete account beside one active account: the active account's height/state still
    /// wins — a completed account contributes nothing.
    @Test func completeAccountBesideActiveAccountContributesNothing() {
        let inputs = [
            MigrationCadence.AccountRearmInput(accountUUID: Self.accountUUID(idByte: 1), state: MigrationState.complete, progress: nil, nextExecutableAfterHeight: nil),
            MigrationCadence.AccountRearmInput(accountUUID: Self.accountUUID(idByte: 2), state: MigrationState.inProgress(Self.progress), progress: Self.progress, nextExecutableAfterHeight: 250)
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
        let account = Self.accountUUID()
        let inputs = [
            MigrationCadence.AccountRearmInput(
                accountUUID: account,
                state: MigrationState.inProgress(progressWithNoReadyHeight),
                progress: progressWithNoReadyHeight,
                nextExecutableAfterHeight: nil
            )
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.representativeState == MigrationState.inProgress(progressWithNoReadyHeight))
        #expect(plan.earliestNextExecutableAfterHeight == nil)
        #expect(plan.nextTransferNumber == 4)
        // R8-T5 (S4): the fallback transfer number's account is tracked too — same fallback branch.
        #expect(plan.winnerAccountUUID == account)
    }

    // MARK: - isUnreadable (R8-T5 #8): conservative-active accounts never resolve `.complete`

    /// An unreadable account beside a genuinely `.complete` account: `representativeState` must NOT
    /// resolve `.complete` — the unreadable account's true state is unknown, so `WakeupAction
    /// .cancelAll` must stay unreachable (mirrors the BG session tree's own `.unreadable`
    /// semantics — `RootInitialization.isDoneClassification`'s doc). #8-a's core assertion.
    @Test func unreadableAccountBesideCompleteAccountIsNotDone() {
        let inputs = [
            MigrationCadence.AccountRearmInput(accountUUID: Self.accountUUID(idByte: 1), state: MigrationState.complete, progress: nil, nextExecutableAfterHeight: nil),
            MigrationCadence.AccountRearmInput(accountUUID: Self.accountUUID(idByte: 2), state: MigrationState.complete, progress: nil, nextExecutableAfterHeight: nil, isUnreadable: true)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.representativeState != MigrationState.complete)
    }

    /// Every account unreadable (#8-b: the all-reads-failed case at the `arm(margin:)` level) is
    /// STILL not done — a retry window must be armable, never a silent skip/cancel. `winnerAccountUUID`
    /// stays nil (S4-c): there is no real account to attribute a notification to here.
    @Test func allAccountsUnreadableIsNotDoneAndHasNoWinner() {
        let inputs = [
            MigrationCadence.AccountRearmInput(accountUUID: Self.accountUUID(idByte: 1), state: MigrationState.complete, progress: nil, nextExecutableAfterHeight: nil, isUnreadable: true),
            MigrationCadence.AccountRearmInput(accountUUID: Self.accountUUID(idByte: 2), state: MigrationState.complete, progress: nil, nextExecutableAfterHeight: nil, isUnreadable: true)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.representativeState != MigrationState.complete)
        #expect(plan.winnerAccountUUID == nil)
        #expect(plan.earliestNextExecutableAfterHeight == nil)
    }

    /// #8-c guard: every account GENUINELY done, with no unreadable ones at all, must still resolve
    /// `.complete` — the fix must not block the legitimate cancelAll path.
    @Test func everyAccountGenuinelyDoneWithNoneUnreadableStillResolvesComplete() {
        let inputs = [
            MigrationCadence.AccountRearmInput(accountUUID: Self.accountUUID(idByte: 1), state: MigrationState.complete, progress: nil, nextExecutableAfterHeight: nil),
            MigrationCadence.AccountRearmInput(accountUUID: Self.accountUUID(idByte: 2), state: MigrationState.notStarted, progress: nil, nextExecutableAfterHeight: nil)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.representativeState == MigrationState.complete)
        #expect(plan.winnerAccountUUID == nil)
    }

    /// An unreadable account must never contribute a winner/transfer-number — only a genuinely-
    /// readable, active account may. Guards against a mismatch (a REAL account's transfer number
    /// attributed to the WRONG, unreadable account, or vice versa) if `isUnreadable` handling were
    /// ever folded into the same bookkeeping the readable branch uses.
    @Test func unreadableAccountDoesNotContributeAWinnerOrTransferNumber() {
        let activeAccount = Self.accountUUID(idByte: 1)
        let unreadableAccount = Self.accountUUID(idByte: 2)
        let progress = MigrationProgress(completedTransfers: 2, totalTransfers: 9, remainingOrchard: Zatoshi(1), nextTransferReadyAtHeight: nil)

        let inputs = [
            MigrationCadence.AccountRearmInput(accountUUID: activeAccount, state: MigrationState.inProgress(progress), progress: progress, nextExecutableAfterHeight: 300),
            MigrationCadence.AccountRearmInput(accountUUID: unreadableAccount, state: MigrationState.complete, progress: nil, nextExecutableAfterHeight: nil, isUnreadable: true)
        ]

        let plan = MigrationCadence.planRearm(inputs)

        #expect(plan.winnerAccountUUID == activeAccount)
        #expect(plan.nextTransferNumber == progress.completedTransfers + 1)
    }
}
