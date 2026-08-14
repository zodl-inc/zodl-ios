//
//  MigrationEngineAnswer.swift
//  zodl
//
//  The engine's next-step answer, in the vocabulary the APP routes on — and the ONE place that
//  translates `MigrationAdvanceStep` into it.
//
//  WHY THIS TYPE EXISTS. Upstream `zcash_pool_migration` retired `AdvanceStep::Attend` and replaced
//  it with two steps that share nothing but their inability to be discharged automatically:
//
//  | upstream step | contracted response | names a transaction? |
//  |---|---|---|
//  | `Replan` | `mark_superseded`, persist, re-plan the remaining balance | NO |
//  | `Reevaluate` | SYNC to at least the tip a rejecting node reported, then ask again | NO |
//
//  `Replan` is an ORDINARY outcome, not a fault: upstream's own words are that a migration whose
//  plan has been undercut — "most often by an ordinary wallet spend consuming notes it had
//  allocated" — surfaces it. `Reevaluate` is not a user-facing state at all; it is the engine
//  saying "your chain view is behind the one that rejected my broadcast, go look again".
//
//  THE SDK SPEAKS THE SPLIT VOCABULARY TOO (2026-08-08 — the landing this file was built to
//  receive, one review cycle ahead of it). `zcashlc_migration_advance_step` marshals each upstream
//  step onto its own BARE discriminant and `MigrationAdvanceStep` carries `.replan` /
//  `.reevaluate` verbatim — no projection, no synthesised id. The interim `.attentionCollapsed`
//  arm (the conduit's old Attend fold, deliberately routed as conservative sync-then-escalate
//  because reading a `Reevaluate` as a replan would tear down a live run whose pre-signed
//  transfers a re-plan discards) was deleted exactly as planned: `init(step:)` gained the two
//  arms below, and nothing downstream moved.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// What the engine answered, as the app routes on it. A verbatim re-expression of
/// `MigrationAdvanceStep` — no case here means anything the engine did not say.
///
/// `nil` (no stored run) is deliberately NOT a case: both consumers already handle "no run"
/// ahead of this type, and with different answers (`MigrationStepPlan` holds `.noRun`,
/// `MigrationState.derive` falls back to the immediate send-max sweep). Folding them together
/// would flatten a distinction that matters.
enum MigrationEngineAnswer: Equatable, Sendable {
    /// The whole provable set, earliest-ready first. Never empty (SDK contract).
    case prove(transactions: [MigrationProveTarget])
    /// This proven transaction is due for delivery, carrying the crank's own opaque instruction.
    ///
    /// NOT a bare id (2026-08-07): the SDK's `.broadcast` step now carries a
    /// `MigrationBroadcastInstruction` the app cannot construct, so possession of one IS the proof
    /// that the app cranked. Re-expressing it as an id here would launder that capability away and
    /// leave the executor un-instructable — this type re-expresses the engine's answer, it does
    /// not weaken it.
    case broadcast(instruction: MigrationBroadcastInstruction)
    /// This transfer expired unmined and must be re-signed in place.
    case rebuild(id: UInt32)
    /// The PLAN needs replacing — its unsatisfiable share passed the engine's replan threshold, or
    /// dead value would otherwise be stranded. Names no transaction: the verdict is about the run,
    /// not about any one row. The app's remedy is the re-plan lane (Figma C5 → B4 → scheduled).
    case replan
    /// A broadcast this app made was REJECTED by the node it went to, and the engine cannot yet say
    /// why: its answer rests on chain state above what this wallet has scanned. Names no
    /// transaction, and asks for nothing but a sync. NOT an attention state — the run is alive and
    /// the user has nothing to decide.
    case reevaluate
    /// Nothing actionable at this height.
    case waiting
    /// The stored run is terminal — every transaction mined, or cancelled/failed/superseded.
    case complete
}

extension MigrationEngineAnswer {
    /// The ONE translation from the SDK's step to the app's vocabulary — 1:1 since the SDK split
    /// `.replan` / `.reevaluate` out of the retired Attend collapse (2026-08-08).
    init(step: MigrationAdvanceStep) {
        switch step {
        case let MigrationAdvanceStep.prove(transactions):
            self = MigrationEngineAnswer.prove(transactions: transactions)
        case let MigrationAdvanceStep.broadcast(instruction):
            self = MigrationEngineAnswer.broadcast(instruction: instruction)
        case let MigrationAdvanceStep.rebuild(id):
            self = MigrationEngineAnswer.rebuild(id: id)
        case MigrationAdvanceStep.replan:
            self = MigrationEngineAnswer.replan
        case MigrationAdvanceStep.reevaluate:
            self = MigrationEngineAnswer.reevaluate
        case MigrationAdvanceStep.waiting:
            self = MigrationEngineAnswer.waiting
        case MigrationAdvanceStep.complete:
            self = MigrationEngineAnswer.complete
        }
    }
}
