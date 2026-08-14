//
//  MigrationStepDriverOnceLatchTests.swift
//  zodlTests
//
//  R0 — "the ground rule of all ground rules" (Lukas, 2026-08-05): one zodl open = ONE
//  `nextStep()` pass. The field case (C6-1, campaign-6, on camera): an open traversing two of
//  Root's `.beforeSync` launch paths drove the engine twice, and with a due pile-up each drive is
//  a BROADCAST — two sends 4 s apart in one session, a ZIP 318 violation (the engine schedules
//  those sends APART). The law is enforced at the driver chokepoint as consumable per-session,
//  per-open-lane credits, FAIL-CLOSED without a live session.
//
//  These tests pin four properties:
//   1. a lane's second same-session call yields, and a new session drives again;
//   2. `.afterSync` gets the identical treatment (it has two call sites of its own);
//   3. the two lanes carry INDEPENDENT credits — one open's designed pair both drive;
//   4. no live session = no drive, and the refusal never burns a credit.
//
//  DETERMINISTIC BY SEAM, not by retries: `MigrationTrace` is process-global and parallel suites
//  begin/end sessions underneath any test that reads it (the churn that retry-hardened this
//  file's first version). The driver reads the ordinal through `sessionOrdinalProvider`, so these
//  tests pin it to a local box and never touch the global trace at all.
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
import ComposableArchitecture
@testable import zodl_internal

@Suite(.serialized) struct MigrationStepDriverOnceLatchTests {
    private static let activationHeight: BlockHeight = 4_134_000
    private static let tip: BlockHeight = 4_200_000

    private static func atTipState() -> SynchronizerState {
        var state = SynchronizerState.zero
        state.latestBlockHeight = tip
        return state
    }

    /// (`.notApplicable` is what a drive verdicts to with no wallet accounts installed — still a
    /// DRIVE: the credit marks attempts, not successes.)
    @Test func aLanesSecondSameSessionCallYieldsAndANewSessionDrives() async {
        await withDependencies {
            $0.sdkSynchronizer = .mocked(latestState: { Self.atTipState() })
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let ordinal = LockIsolated<Int?>(7)
            let manager = MigrationManagerImpl(sessionOrdinalProvider: { ordinal.value })

            let first = await manager.advance(phase: .beforeSync)
            let second = await manager.advance(phase: .beforeSync)
            #expect(first == .notApplicable, "the session's one beforeSync drive")
            #expect(second == .skipped, "same session, second call — the credit is spent")

            ordinal.setValue(8)
            let nextSession = await manager.advance(phase: .beforeSync)
            #expect(nextSession == .notApplicable, "a NEW session arms a new credit")
        }
    }

    @Test func afterSyncCarriesTheSameOncePerSessionCredit() async {
        await withDependencies {
            $0.sdkSynchronizer = .mocked(latestState: { Self.atTipState() })
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let ordinal = LockIsolated<Int?>(3)
            let manager = MigrationManagerImpl(sessionOrdinalProvider: { ordinal.value })

            let first = await manager.advance(phase: .afterSync)
            let second = await manager.advance(phase: .afterSync)
            #expect(first == .notApplicable, "the session's one afterSync drive")
            #expect(second == .skipped, "a re-firing sync edge in the same session yields")

            ordinal.setValue(4)
            let nextSession = await manager.advance(phase: .afterSync)
            #expect(nextSession == .notApplicable, "the next open's edge drives again")
        }
    }

    /// One open's DESIGNED pair: `.beforeSync` then `.afterSync` are the two moments of the same
    /// open (MigrationStepPlan's "THE TWO PHASES") — each holds its own credit, so the pair both
    /// drive while every repeat of either yields.
    @Test func theTwoOpenLanesCarryIndependentCreditsWithinOneOpen() async {
        await withDependencies {
            $0.sdkSynchronizer = .mocked(latestState: { Self.atTipState() })
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let manager = MigrationManagerImpl(sessionOrdinalProvider: { 11 })

            let beforeFirst = await manager.advance(phase: .beforeSync)
            let afterFirst = await manager.advance(phase: .afterSync)
            let beforeRepeat = await manager.advance(phase: .beforeSync)
            let afterRepeat = await manager.advance(phase: .afterSync)

            #expect(beforeFirst == .notApplicable, "the open's pre-wire moment drives")
            #expect(afterFirst == .notApplicable, "the open's edge moment drives on its OWN credit")
            #expect(beforeRepeat == .skipped, "beforeSync repeat yields")
            #expect(afterRepeat == .skipped, "afterSync repeat yields")
        }
    }

    /// R0 is FAIL-CLOSED: an open-lane drive with no live session is refused outright — a
    /// background wake-up or a stray completion handler cannot drive the engine — and the refusal
    /// burns nothing: the session that eventually opens still gets its full pair.
    @Test func openLaneDrivesAreRefusedWithoutALiveSessionAndBurnNoCredit() async {
        await withDependencies {
            $0.sdkSynchronizer = .mocked(latestState: { Self.atTipState() })
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let ordinal = LockIsolated<Int?>(nil)
            let manager = MigrationManagerImpl(sessionOrdinalProvider: { ordinal.value })

            let sessionlessBefore = await manager.advance(phase: .beforeSync)
            let sessionlessAfter = await manager.advance(phase: .afterSync)
            #expect(sessionlessBefore == .skipped, "no session — beforeSync is fail-closed")
            #expect(sessionlessAfter == .skipped, "no session — afterSync is fail-closed")

            ordinal.setValue(21)
            let openedBefore = await manager.advance(phase: .beforeSync)
            let openedAfter = await manager.advance(phase: .afterSync)
            #expect(openedBefore == .notApplicable, "the open that follows still gets its beforeSync")
            #expect(openedAfter == .notApplicable, "…and its afterSync")
        }
    }

    /// G1 (field 2026-08-05, Lukas: "I was hoping to trigger first nextStep with the start
    /// migration button"): a fresh commit REFUNDS the session's open-lane credits. The session
    /// that commits typically spent its credits on the PRE-commit "noRun" pass, and R0's law bans
    /// re-driving the SAME state — a run that did not exist at the earlier drive is not the same
    /// state. Without the refund, the newborn run's first step waited for the next app-open.
    @Test func aFreshCommitRefundsTheSessionsOpenLaneCredits() async {
        await withDependencies {
            $0.sdkSynchronizer = .mocked(latestState: { Self.atTipState() })
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let manager = MigrationManagerImpl(sessionOrdinalProvider: { 31 })

            let preCommit = await manager.advance(phase: .afterSync)
            let spent = await manager.advance(phase: .afterSync)
            #expect(preCommit == .notApplicable, "the pre-commit pass consumes the credit")
            #expect(spent == .skipped, "…and a plain repeat is refused")

            await manager.recordCommittedSchedule(
                accountUUID: AccountUUID(id: [UInt8](repeating: 0x07, count: 16)),
                schedule: MigrationSchedule(
                    transfers: [],
                    estimatedDurationHours: 1,
                    proposalHandle: 7,
                    preparations: []
                )
            )

            let postCommit = await manager.advance(phase: .afterSync)
            #expect(postCommit == .notApplicable, "the commit's own drive proceeds on the refunded credit")
        }
    }
}
