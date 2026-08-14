//
//  MigrationReplanRoutingTests.swift
//  zodlTests
//
//  Upstream's `AdvanceStep::Replan` and `AdvanceStep::Reevaluate` drive the app's lanes
//  (MOB-1466, Lukas 2026-08-07: "replan is now a regular advanceMigration result.. we MUST never
//  map it to anything else").
//
//  WHAT THESE PIN, AND WHY THEY EXIST BEFORE THE SDK DOES. `zcashlc_migration_advance_step` still
//  folds both upstream steps into one `ZCASHLC_ADVANCE_STEP_ATTEND` with a synthesised transaction
//  id; nuttycom is splitting them SDK-side. `MigrationEngineAnswer` is the app's own vocabulary, so
//  the two lanes are wired, routed and pinned NOW — and go live on the SDK landing without a
//  behaviour change anywhere below the translation point.
//
//  The two lanes are opposites, which is the whole reason collapsing them is a bug:
//
//  | answer | first beat | involves the user? |
//  |---|---|---|
//  | `.replan` | hand off immediately — no sync | YES, straight to the re-plan lane |
//  | `.reevaluate` | sync and re-ask | NEVER |
//

import Foundation
import Testing
@_spi(Testing) import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationReplanRoutingTests {
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

    private static let progress = MigrationProgress(
        completedTransfers: 2,
        totalTransfers: 11,
        remainingOrchard: Zatoshi(145_000_000),
        nextTransferReadyAtHeight: nil
    )

    // MARK: - The step plan

    /// THE FIX, and the reason telling replan apart is worth anything: NO WASTED SYNC. Upstream
    /// decides a replan against state it has already persisted, so scanning more blocks cannot
    /// change the answer — routed through the collapsed attention bucket it cost a whole pass.
    @Test func replanHandsOffAtEveryPhaseAndNeverResyncs() {
        for phase in [MigrationOpenPhase.beforeSync, .afterSync, .tick] {
            #expect(
                MigrationStepPlan.action(for: MigrationEngineAnswer.replan, phase: phase)
                    == MigrationStepAction.replan,
                "replan must hand off at \(phase) rather than sync or defer"
            )
        }
    }

    /// A reevaluate's ENTIRE contracted discharge is "sync, then ask again".
    @Test func reevaluateSyncsBeforeSyncAndDefersElsewhere() {
        #expect(
            MigrationStepPlan.action(for: MigrationEngineAnswer.reevaluate, phase: .beforeSync)
                == MigrationStepAction.reevaluate
        )
        #expect(
            MigrationStepPlan.action(for: MigrationEngineAnswer.reevaluate, phase: .afterSync)
                == MigrationStepAction.nothing(MigrationStepHold.wrongPhase)
        )
        #expect(
            MigrationStepPlan.action(for: MigrationEngineAnswer.reevaluate, phase: .tick)
                == MigrationStepAction.nothing(MigrationStepHold.wrongPhase)
        )
    }

    /// THE GUARD THAT MATTERS MOST on the reevaluate side. Upstream surfaces `Reevaluate`
    /// unconditionally and keeps surfacing it until the wallet's scan reaches the tip that rejected
    /// the broadcast — which can span sessions. Escalating it would tell the user to re-plan a
    /// perfectly live run whose transfers are all intact.
    @Test func reevaluateNeverEscalatesToTheUser() {
        #expect(MigrationStepPlan.action(for: MigrationEngineAnswer.reevaluate, phase: .beforeSync) == .reevaluate)
        for phase in [MigrationOpenPhase.afterSync, .tick] {
            let action = MigrationStepPlan.action(for: MigrationEngineAnswer.reevaluate, phase: phase)
            #expect(
                action == .nothing(.wrongPhase),
                "reevaluate after a sync ends the session honestly — it never escalates"
            )
            #expect(action != MigrationStepAction.replan, "reevaluate must never enter the re-plan lane")
        }
    }

    /// NEITHER LANE CARRIES AN ID, because neither upstream step names a transaction — the retired
    /// collapsed conduit used to synthesise one (falling back to transfer `0`). The app's actions
    /// are id-free by construction, so no invented id can reach a surface through them.
    @Test func neitherLaneCarriesATransactionId() {
        let replan = MigrationStepPlan.action(for: MigrationEngineAnswer.replan, phase: .beforeSync)
        let reevaluate = MigrationStepPlan.action(for: MigrationEngineAnswer.reevaluate, phase: .beforeSync)

        for action in [replan, reevaluate] {
            switch action {
            case .rebuild(let id):
                Issue.record("an id-free engine answer produced an id-carrying action (\(id))")
            case .broadcast(let instruction):
                // Since 2026-08-07 the broadcast action carries the crank's opaque instruction
                // rather than a bare id; an id-free answer must still never produce one.
                Issue.record("an id-free engine answer produced a broadcast action (\(instruction.id))")
            case .prove(let instruction):
                Issue.record("an id-free engine answer produced a prove action (\(instruction.map(\.id)))")
            case .replan, .reevaluate, .armWakeups, .finish, .nothing:
                break
            }
        }
    }

    // MARK: - The state derivation

    /// `.replan` reaches the SAME app state the notes-spent lane already uses — which is what makes
    /// the banner say "Update migration plan" and the re-entry route land on the Figma C5 screen,
    /// with no new copy invented for it. `MigrationAttentionReason` names the REMEDY, and a
    /// replan's remedy is a re-plan.
    @Test func replanDerivesTheUpdatePlanAttentionState() {
        #expect(
            MigrationState.derive(
                answer: MigrationEngineAnswer.replan,
                progress: Self.progress,
                statuses: [Self.transferStatus(id: 0, state: .signed)],
                hasInvalidTransfers: false
            ) == .requiresAttention(.invalidTransfer)
        )
    }

    /// `.reevaluate` is NOT an attention state — the run is alive and the user has nothing to
    /// decide. It reads as the in-progress run it is.
    @Test func reevaluateDerivesAnInProgressStateNotAttention() {
        let state = MigrationState.derive(
            answer: MigrationEngineAnswer.reevaluate,
            progress: Self.progress,
            statuses: [Self.transferStatus(id: 0, state: .mined(height: 4_243_100))],
            hasInvalidTransfers: false
        )

        #expect(state == .inProgress(Self.progress))
        if case MigrationState.requiresAttention = state {
            Issue.record("a reevaluate painted an attention state over a live run")
        }
    }

    /// The engine's own run-level invalidation still outranks everything, replan included — a
    /// coverage failure the engine reports separately must not be masked by the step arm.
    @Test func hasInvalidStillOutranksTheReevaluateArm() {
        #expect(
            MigrationState.derive(
                answer: MigrationEngineAnswer.reevaluate,
                progress: Self.progress,
                statuses: [],
                hasInvalidTransfers: true
            ) == .requiresAttention(.invalidTransfer)
        )
    }

    // MARK: - The re-entry route

    /// The route the Figma flow hangs off: banner "Update migration plan" -> More -> C5 "Reschedule
    /// Transfers" -> Continue -> fresh plan -> Scheduling… -> Migration Scheduled. `isExpired` is
    /// FALSE — a replan is about the plan's coverage, never about a transfer's expiry, so it must
    /// not land on the expired-rebuild copy.
    @Test func replanRoutesToTheNotesSpentRecoveryScreen() {
        #expect(
            MigrationDerivations.reentryRoute(
                isIronwoodActivated: true,
                state: .requiresAttention(.invalidTransfer),
                answer: MigrationEngineAnswer.replan,
                hasInvalid: false,
                hasOverdue: false,
                isCompleteAcknowledged: false,
                progress: Self.progress
            ) == MigrationReentryRoute.recovery(isExpired: false)
        )
    }

    /// Even when the app's own state happens to read `.transferExpired`, a replan stays on the
    /// notes-spent screen: the engine named the answer, and the expiry read exists only to
    /// disambiguate the COLLAPSED bucket.
    @Test func replanIgnoresTheExpiredStateRead() {
        #expect(
            MigrationDerivations.reentryRoute(
                isIronwoodActivated: true,
                state: .requiresAttention(.transferExpired),
                answer: MigrationEngineAnswer.replan,
                hasInvalid: false,
                hasOverdue: false,
                isCompleteAcknowledged: false,
                progress: Self.progress
            ) == MigrationReentryRoute.recovery(isExpired: false)
        )
    }

    /// A reevaluate must not hand the user a "re-plan this run" button.
    @Test func reevaluateDoesNotRouteToRecovery() {
        let route = MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: .inProgress(Self.progress),
            answer: MigrationEngineAnswer.reevaluate,
            hasInvalid: false,
            hasOverdue: false,
            isCompleteAcknowledged: false,
            progress: Self.progress
        )

        if case MigrationReentryRoute.recovery = route {
            Issue.record("a reevaluate routed the user to the re-plan lane")
        }
    }

    // MARK: - The translation point, and the regression guard on it

    /// Every step the SDK can hand us maps VERBATIM — `.replan`/`.reevaluate` included since the
    /// 2026-08-08 split (the two arms this suite was written to receive; `.attentionCollapsed`
    /// left the list with the collapse).
    @Test func theTranslationIsVerbatim() {
        let target = MigrationProveTarget(id: 7, kind: .transfer(crossing: 1))

        #expect(MigrationEngineAnswer(step: .prove(transactions: [target])) == .prove(transactions: [target]))
        let instruction = MigrationBroadcastInstruction(id: 3)
        #expect(MigrationEngineAnswer(step: .broadcast(instruction)) == .broadcast(instruction: instruction))
        #expect(MigrationEngineAnswer(step: .rebuild(id: 4)) == .rebuild(id: 4))
        #expect(MigrationEngineAnswer(step: .waiting) == .waiting)
        #expect(MigrationEngineAnswer(step: .complete) == .complete)
        #expect(MigrationEngineAnswer(step: .replan) == .replan)
        #expect(MigrationEngineAnswer(step: .reevaluate) == .reevaluate)
    }

}
