//
//  MigrationVisitTests.swift
//  zodlTests
//
//  Covers `MigrationVisit.decide` — the app half of ZIP 318's session separation. The engine says
//  WHAT to do next and is explicitly memoryless about sessions; this decides WHICH KIND of session
//  an app-open is, and it is the single place that answer is made.
//
//  Two properties are worth pinning against future edits: the decision is WALLET-WIDE (one account
//  mid-broadcast keeps the whole wallet off the wire), and a PREPARATION is not a broadcast session
//  (upstream proves and broadcasts preparations at the same wake-up — they anchor at the tip, so
//  nothing about them is timing-correlated with a pool crossing).
//

import Testing
@_spi(Testing) import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationVisitTests {
    private static let transferKind = MigrationTransactionStatus.Kind.transfer(crossing: 0)
    private static let preparationKind = MigrationTransactionStatus.Kind.preparation(layer: 0, index: 0)

    // MARK: - The one case that suppresses sync

    @Test func aDueBroadcastMakesItASendVisit() {
        #expect(MigrationVisit.decide(advanceSteps: [.broadcast(MigrationBroadcastInstruction(id: 7))]) == .send)
    }

    /// Wallet-wide: sync is one wallet-level activity, so one account mid-broadcast keeps every
    /// account off the wire. A Zodl wallet and a Keystone wallet run independent plans but share
    /// one network identity.
    @Test func oneAccountsBroadcastSuppressesSyncForTheWholeWallet() {
        let steps: [MigrationAdvanceStep?] = [.waiting, .broadcast(MigrationBroadcastInstruction(id: 3)), nil]
        #expect(MigrationVisit.decide(advanceSteps: steps) == .send)
    }

    // MARK: - Everything else syncs

    @Test func provingATransferIsASyncVisit() {
        // Proving is sync-BOUND: it resolves anchors and witnesses from the synced tree, so this
        // session must sync. Its broadcast comes later, in its own session.
        #expect(MigrationVisit.decide(advanceSteps: [.prove(transactions: [MigrationProveTarget(id: 1, kind: Self.transferKind)])]) == .sync)
    }

    /// The documented exception: a preparation is proved AND broadcast at the same wake-up, because
    /// it anchors to a fresh checkpoint at the tip like an ordinary transaction. It must not
    /// suppress sync.
    @Test func provingAPreparationIsStillASyncVisit() {
        #expect(MigrationVisit.decide(advanceSteps: [.prove(transactions: [MigrationProveTarget(id: 1, kind: Self.preparationKind)])]) == .sync)
    }

    @Test(arguments: [MigrationAdvanceStep.waiting, .complete, .rebuild(id: 2)])
    func nonBroadcastStepsAreSyncVisits(step: MigrationAdvanceStep) {
        #expect(MigrationVisit.decide(advanceSteps: [step]) == .sync)
    }

    @Test func noAccountsAtAllSyncs() {
        #expect(MigrationVisit.decide(advanceSteps: []) == .sync)
    }

    /// A `nil` step is "no stored run, or the read failed" — it does not vote either way, and must
    /// never by itself suppress sync.
    @Test func nilStepsDoNotVote() {
        #expect(MigrationVisit.decide(advanceSteps: [nil, nil]) == .sync)
        #expect(MigrationVisit.decide(advanceSteps: [nil, .broadcast(MigrationBroadcastInstruction(id: 1))]) == .send)
    }

    // MARK: - Kind-aware broadcasts (AUD-3)

    /// A due PREPARATION broadcast is ZIP-exempt from the session separation ("a fully shielded
    /// send-to-self") — its open stays a sync session, exactly the wake-up that proves AND
    /// broadcasts it.
    @Test func aDuePreparationBroadcastStaysASyncVisit() {
        #expect(MigrationVisit.decide(advanceSteps: [.broadcast(MigrationBroadcastInstruction(id: 7))], preparationIds: [7]) == .sync)
    }

    /// A due TRANSFER beside a due preparation still suppresses sync — the exemption is
    /// per-transaction, never per-open.
    @Test func aDueTransferBesideAPreparationIsStillASendVisit() {
        let steps: [MigrationAdvanceStep?] = [.broadcast(MigrationBroadcastInstruction(id: 7)), .broadcast(MigrationBroadcastInstruction(id: 3))]
        #expect(MigrationVisit.decide(advanceSteps: steps, preparationIds: [7]) == .send)
    }

    /// The conservative default: with no id set supplied, every broadcast is treated as a
    /// transfer — the pre-AUD-3 behavior, and the safe direction for a failed statuses read.
    @Test func withoutAKindSetEveryBroadcastIsATransfer() {
        #expect(MigrationVisit.decide(advanceSteps: [.broadcast(MigrationBroadcastInstruction(id: 7))]) == .send)
    }
}
