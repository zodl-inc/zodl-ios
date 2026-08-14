//
//  MigrationStepPlanTests.swift
//  zodlTests
//
//  The decision table of `MigrationStepPlan`, pinned case by case.
//
//  This suite exists because of a specific failure: the app read the engine's next step in ONE
//  place, branched on `.broadcast`, and discarded the other five answers. Two of them — `.rebuild`
//  and `.requiresAttention` — had no automatic discharge anywhere in the app, so a run whose next
//  step was either of those stopped and stayed stopped across any number of app-opens. Nothing
//  failed, nothing logged, nothing was wrong on any screen; the app simply never did the thing it
//  had been told to do.
//
//  So the tests below are not really about the return values. They are about COVERAGE: every case
//  of `MigrationAdvanceStep`, at both phases, produces an action that some executor honours. The
//  planner's own `switch` has no `default:`, which makes a NEW step a compile error; this suite is
//  the other half — it makes a step that compiles but goes nowhere a test failure.
//

import Testing
@_spi(Testing) import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationStepPlanTests {
    // MARK: - The two steps that used to deadlock

    /// `.rebuild` had exactly one discharge in the whole app: a button on the Recovery screen. The
    /// planner must name it as work, at the phase where the wallet is at the tip.
    @Test func rebuildIsDischargedAtThePostSyncEdge() {
        #expect(MigrationStepPlan.action(for: .rebuild(id: 7), phase: .afterSync) == .rebuild(id: 7))
    }

    /// Before sync it defers rather than acting: a rebuild re-anchors rows against the CURRENT tip,
    /// so rebuilding from a stale one would rebuild them straight back into staleness.
    @Test func rebuildDefersBeforeSync() {
        #expect(MigrationStepPlan.action(for: .rebuild(id: 7), phase: .beforeSync) == .nothing(.wrongPhase))
    }

    /// The split vocabulary at the SDK-typed entry point (2026-08-08, replacing the retired
    /// collapsed bucket's sync-then-escalate pair): `.replan` enters the re-plan lane in EVERY
    /// phase — the verdict is persisted, no sync changes it — and `.reevaluate` syncs at
    /// `.beforeSync`.
    @Test func replanAndReevaluateRouteDirectlyAtTheSdkTypedEntryPoint() {
        #expect(MigrationStepPlan.action(for: MigrationAdvanceStep.replan, phase: .beforeSync) == .replan)
        #expect(MigrationStepPlan.action(for: MigrationAdvanceStep.replan, phase: .afterSync) == .replan)
        #expect(MigrationStepPlan.action(for: MigrationAdvanceStep.reevaluate, phase: .beforeSync) == .reevaluate)
    }

    // MARK: - ZIP 318 session separation, enforced structurally

    /// A broadcast may only happen in a session that has not synced. Enforced by the TABLE rather
    /// than by a caller remembering — a caller that forgets is how the property gets lost.
    @Test func broadcastIsOfferedOnlyBeforeSync() {
        #expect(MigrationStepPlan.action(for: .broadcast(MigrationBroadcastInstruction(id: 5)), phase: .beforeSync) == .broadcast(MigrationBroadcastInstruction(id: 5)))
        #expect(MigrationStepPlan.action(for: .broadcast(MigrationBroadcastInstruction(id: 5)), phase: .afterSync) == .nothing(.wrongPhase))
    }

    /// The mirror: proving needs the commitment tree at the tip, so it only happens after a sync —
    /// and never in a broadcast session, where it would force that session onto the wire.
    @Test func proveIsOfferedOnlyAfterSync() {
        let step = MigrationAdvanceStep.prove(transactions: [MigrationProveTarget(id: 1, kind: .transfer(crossing: 0))])

        #expect(MigrationStepPlan.action(for: step, phase: .afterSync) == .prove(instruction: [MigrationProveTarget(id: 1, kind: .transfer(crossing: 0))]))
        #expect(MigrationStepPlan.action(for: step, phase: .beforeSync) == .nothing(.wrongPhase))
    }

    /// Both kinds prove, and the action carries the batch, kinds included. The head's kind is read
    /// at the discharge (never a statuses re-read, never a `next_step` re-ask) — today only to log
    /// and route, since the pass ends at the proof for every kind. See
    /// `MigrationStepDriver.execute`'s prove arm for why D2's same-pass preparation delivery is
    /// currently withheld.
    @Test func bothProveKindsProveButTheActionCarriesTheKind() {
        let preparation = MigrationAdvanceStep.prove(transactions: [MigrationProveTarget(id: 9, kind: .preparation(layer: 0, index: 0))])
        let transfer = MigrationAdvanceStep.prove(transactions: [MigrationProveTarget(id: 9, kind: .transfer(crossing: 0))])

        #expect(MigrationStepPlan.action(for: preparation, phase: .afterSync) == .prove(instruction: [MigrationProveTarget(id: 9, kind: .preparation(layer: 0, index: 0))]))
        #expect(MigrationStepPlan.action(for: transfer, phase: .afterSync) == .prove(instruction: [MigrationProveTarget(id: 9, kind: .transfer(crossing: 0))]))
    }

    /// #2939 batch step.
    /// 2026-08-07: this pinned the table PROJECTING the batch down to its head
    /// (`.prove(id:isPreparation:)`). It no longer projects — the SDK's prove executor takes the
    /// batch, so the table passes the whole instruction through UNCHANGED and in order, and the
    /// head is read at the discharge instead. That pass-through is what this pins now: dropping or
    /// reordering entries here would silently shrink what gets proved.
    @Test func aBatchProvePassesTheWholeInstructionThrough() {
        let batch = [
            MigrationProveTarget(id: 4, kind: .transfer(crossing: 0)),
            MigrationProveTarget(id: 9, kind: .preparation(layer: 0, index: 0))
        ]
        let step = MigrationAdvanceStep.prove(transactions: batch)
        #expect(MigrationStepPlan.action(for: step, phase: .afterSync) == .prove(instruction: batch))
        #expect(MigrationStepPlan.action(for: step, phase: .tick) == .prove(instruction: batch))
    }

    /// The mirror order: a preparation head is carried through with its transfer still queued
    /// behind it, so the discharge can read the head's kind and route the same-wake-up broadcast.
    @Test func aPreparationHeadIsCarriedThroughAheadOfItsTransfer() {
        let batch = [
            MigrationProveTarget(id: 2, kind: .preparation(layer: 1, index: 0)),
            MigrationProveTarget(id: 7, kind: .transfer(crossing: 0))
        ]
        let step = MigrationAdvanceStep.prove(transactions: batch)
        #expect(MigrationStepPlan.action(for: step, phase: .afterSync) == .prove(instruction: batch))
        #expect(batch[0].kind.isPreparation, "the discharge routes the same-wake-up broadcast off this head")
    }

    // MARK: - The quiet answers

    @Test func waitingArmsWakeupsAtBothPhases() {
        #expect(MigrationStepPlan.action(for: .waiting, phase: .beforeSync) == .armWakeups)
        #expect(MigrationStepPlan.action(for: .waiting, phase: .afterSync) == .armWakeups)
    }

    @Test func completeIsTerminalAtBothPhases() {
        #expect(MigrationStepPlan.action(for: .complete, phase: .beforeSync) == .finish)
        #expect(MigrationStepPlan.action(for: .complete, phase: .afterSync) == .finish)
    }

    /// `nil` is the benign "no run was ever committed" answer, and it must be distinguishable from
    /// a deferred step — the two look identical on screen and could not be told apart in a log.
    @Test func noStoredRunIsItsOwnAnswerNotADeferral() {
        #expect(MigrationStepPlan.action(for: nil, phase: .beforeSync) == .nothing(.noRun))
        #expect(MigrationStepPlan.action(for: nil, phase: .afterSync) == .nothing(.noRun))
    }

    // MARK: - The tick column (MOB-1466): a foreground TICK is a broadcast opportunity

    /// A tick reproduces exactly what `.beforeSync` already offers a due broadcast — one more
    /// chance to deliver it, without a sync of its own. See the file header's tick-column note for
    /// why that correlation story is what makes a tick safe to broadcast from at all.
    @Test func tickBroadcastsADueTransfer() {
        #expect(MigrationStepPlan.action(for: .broadcast(MigrationBroadcastInstruction(id: 5)), phase: .tick) == .broadcast(MigrationBroadcastInstruction(id: 5)))
    }

    /// Proving, rebuilding, and reevaluation all stay pinned to the two moments that bracket an
    /// actual sync. A tick runs no sync of its own, so none of the three gains a new discharge
    /// here — only the phase check stands between them and the open/edge that already owns them.
    /// (`.replan` is the deliberate exception — phase-independent, pinned in the replan suite.)
    @Test func tickDefersRebuildAndReevaluateToTheOpensAndEdges() {
        #expect(MigrationStepPlan.action(for: .rebuild(id: 7), phase: .tick) == .nothing(.wrongPhase))
        #expect(MigrationStepPlan.action(for: MigrationAdvanceStep.reevaluate, phase: .tick) == .nothing(.wrongPhase))
    }

    // MARK: - The unconditional tick prove (FIND-5, 2026-08-05)

    /// A tick proves whatever the engine says is provable, with NO tip condition. Both prior
    /// shapes of this cell starved a real session — full deferral starved follow-mode (no sync
    /// edge ever re-fires), and the at-tip gate that replaced it starved the marathon session
    /// (broadcast churn plus the sync gate's ready-broadcast hold kept `syncStatus` off
    /// `.upToDate` for 50+ minutes, collapsing proving to one sweep per app-REOPEN under a
    /// "Keep Zodl open" banner). The engine's `.prove` answer is scanned-frame truth and the
    /// sweep is safe on any schedule — the tick obeys it, full stop. This test is the
    /// anti-regression pin for BOTH failure modes.
    @Test func tickProvesUnconditionally() {
        let transfer = MigrationAdvanceStep.prove(transactions: [MigrationProveTarget(id: 1, kind: .transfer(crossing: 0))])
        let preparation = MigrationAdvanceStep.prove(transactions: [MigrationProveTarget(id: 1, kind: .preparation(layer: 0, index: 0))])

        #expect(MigrationStepPlan.action(for: transfer, phase: .tick) == .prove(instruction: [MigrationProveTarget(id: 1, kind: .transfer(crossing: 0))]))
        #expect(MigrationStepPlan.action(for: preparation, phase: .tick) == .prove(instruction: [MigrationProveTarget(id: 1, kind: .preparation(layer: 0, index: 0))]))
    }

    /// The tick prove changes nothing about the other cells: `.beforeSync` keeps deferring the
    /// prove (its own edge is moments away, and the open must stay free to broadcast instead),
    /// and rebuild/attention keep their edge anchoring untouched.
    @Test func tickProveLeavesEveryOtherCellAlone() {
        let transfer = MigrationAdvanceStep.prove(transactions: [MigrationProveTarget(id: 1, kind: .transfer(crossing: 0))])

        #expect(MigrationStepPlan.action(for: transfer, phase: .beforeSync) == .nothing(.wrongPhase))
        #expect(MigrationStepPlan.action(for: .rebuild(id: 7), phase: .tick) == .nothing(.wrongPhase))
        #expect(MigrationStepPlan.action(for: MigrationAdvanceStep.reevaluate, phase: .tick) == .nothing(.wrongPhase))
    }

    /// The two answers that never depended on a phase in the first place stay that way with a third
    /// phase in play.
    @Test func tickArmsWakeupsAndFinishesLikeEveryOtherPhase() {
        #expect(MigrationStepPlan.action(for: .waiting, phase: .tick) == .armWakeups)
        #expect(MigrationStepPlan.action(for: .complete, phase: .tick) == .finish)
    }

    /// No stored run reads the same at a tick as at either open — it is the benign answer, not a
    /// deferral, everywhere `nil` shows up.
    @Test func tickWithNoStoredRunIsNoRun() {
        #expect(MigrationStepPlan.action(for: nil, phase: .tick) == .nothing(.noRun))
    }

    // MARK: - Coverage: no step may go nowhere

    /// THE invariant, stated directly: across the two phases, EVERY engine step produces at least
    /// one real action. A step that answers `.nothing` at both phases is a step nothing in the app
    /// will ever discharge — which is precisely the bug this whole file was written against.
    @Test func everyStepIsActionableAtSomePhase() {
        let everyStep: [MigrationAdvanceStep] = [
            .broadcast(MigrationBroadcastInstruction(id: 1)),
            .prove(transactions: [MigrationProveTarget(id: 1, kind: .transfer(crossing: 0))]),
            .prove(transactions: [MigrationProveTarget(id: 1, kind: .preparation(layer: 0, index: 0))]),
            .rebuild(id: 1),
            .replan,
            .reevaluate,
            .waiting,
            .complete
        ]

        for step in everyStep {
            let before = MigrationStepPlan.action(for: step, phase: .beforeSync)
            let after = MigrationStepPlan.action(for: step, phase: .afterSync)

            let isActionable = !Self.isInert(before) || !Self.isInert(after)
            #expect(isActionable, "\(step) produces no work at either phase — nothing would ever discharge it")
        }
    }

    private static func isInert(_ action: MigrationStepAction) -> Bool {
        if case .nothing = action { return true }
        return false
    }

    // MARK: - The wallet-wide session decision

    /// One account mid-broadcast puts the WHOLE wallet off the wire: a Zodl account and a Keystone
    /// account run independent plans but share one network identity.
    @Test func anyDueBroadcastMakesTheWholeSessionABroadcastSession() {
        #expect(MigrationStepPlan.isBroadcastSession(steps: [.waiting, .broadcast(MigrationBroadcastInstruction(id: 3))]))
    }

    /// `nil` entries (an account with no run, or a read that failed) do not vote.
    @Test func accountsWithNoRunDoNotVote() {
        #expect(!MigrationStepPlan.isBroadcastSession(steps: [nil, nil]))
        #expect(!MigrationStepPlan.isBroadcastSession(
            steps: [
                nil,
                .prove(transactions: [MigrationProveTarget(id: 1, kind: .preparation(layer: 0, index: 0))])
            ]
        ))
    }

    /// The session decision must agree with `MigrationVisit`, which Root still asks separately
    /// before `start()`. Two readings of the same rule in two places is how the "two clocks" class
    /// of bug starts, so they are pinned against each other here.
    @Test func theSessionDecisionAgreesWithMigrationVisit() {
        let cases: [[MigrationAdvanceStep?]] = [
            [],
            [nil],
            [.waiting],
            [.broadcast(MigrationBroadcastInstruction(id: 1))],
            [.prove(transactions: [MigrationProveTarget(id: 1, kind: .preparation(layer: 0, index: 0))]), .broadcast(MigrationBroadcastInstruction(id: 2))],
            [.rebuild(id: 1), .replan]
        ]

        for steps in cases {
            let planSaysSend = MigrationStepPlan.isBroadcastSession(steps: steps)
            let visitSaysSend = MigrationVisit.decide(advanceSteps: steps) == .send

            #expect(planSaysSend == visitSaysSend, "disagreement on \(steps)")
        }
    }
}
