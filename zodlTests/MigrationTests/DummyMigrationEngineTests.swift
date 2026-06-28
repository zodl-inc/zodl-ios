//
//  DummyMigrationEngineTests.swift
//  zodlTests
//
//  Exercises the simulated migration engine end-to-end.
//

import Testing
import Foundation
@testable import zodl_internal
@preconcurrency import ZcashLightClientKit

@Suite(.serialized)
struct DummyMigrationEngineTests {
    private func makeEngine() -> DummyMigrationEngine {
        DummyMigrationEngine(store: .ephemeral())
    }

    @Test func noteSplitNeededAndProposalForPrivateMode() async {
        let engine = makeEngine()
        await engine.debugSeed(orchard: Zatoshi(1_000_000_000), noteCount: 0) // 10 ZEC
        engine.selectMode(.privateScheduled)

        #expect(engine.noteSplitNeeded())

        let proposal = await engine.prepareSplit()
        #expect(proposal.outputNotes.count >= 2)
        let sum = proposal.outputNotes.reduce(Int64(0)) { $0 + $1.amount }
        #expect(sum <= 1_000_000_000)
    }

    @Test func prepareSplitProducesFiveToEightNotesSummingToNet() async {
        let engine = makeEngine()
        await engine.debugSeed(orchard: Zatoshi(1_245_800_000), noteCount: 0) // ≈12.458 ZEC, no override
        engine.selectMode(.privateScheduled)

        let proposal = await engine.prepareSplit()

        #expect((5...8).contains(proposal.outputNotes.count))
        #expect(proposal.outputNotes.allSatisfy { $0.amount > 0 })
        let sum = proposal.outputNotes.reduce(Int64(0)) { $0 + $1.amount }
        let net = 1_245_800_000 - proposal.fee.amount
        #expect(sum == net)
    }

    @Test func noteCountOverrideForcesExactTransferCount() async {
        let engine = makeEngine()
        await engine.debugSeed(orchard: Zatoshi(1_245_800_000), noteCount: 6)
        engine.selectMode(.privateScheduled)

        let proposal = await engine.prepareSplit()
        _ = await engine.submitSplit(proposal)
        engine.confirmSplit()
        let schedule = await engine.propose()

        #expect(proposal.outputNotes.count == 6)
        #expect(schedule.transfers.count == 6)
        // Transfer 1 is executable now; the rest are spaced one bucket apart, durations 6h apart.
        #expect(schedule.estimatedDurationHours == 30) // 6 * (6 - 1)
    }

    @Test func privateFlowProgressesToComplete() async {
        let engine = makeEngine()
        await engine.debugSeed(orchard: Zatoshi(1_000_000_000), noteCount: 0)
        engine.selectMode(.privateScheduled)

        let proposal = await engine.prepareSplit()
        _ = await engine.submitSplit(proposal)
        #expect(engine.currentState() == .splitPendingConfirmation)

        engine.confirmSplit()
        #expect(engine.currentState() == .readyToPropose)

        let schedule = await engine.propose()
        #expect(schedule.transfers.count >= 2)
        let heights = schedule.transfers.map { $0.nextExecutableAfterHeight }
        #expect(heights == heights.sorted())
        #expect(Set(heights).count == heights.count)

        await engine.signAndStore(schedule)
        guard case let .inProgress(progress) = engine.currentState() else {
            Issue.record("expected inProgress")
            return
        }
        #expect(progress.totalTransfers == schedule.transfers.count)

        for _ in 0..<schedule.transfers.count {
            _ = await engine.executeNext(NetworkPrivacyOptions(useTor: false))
        }
        #expect(engine.currentState() == .complete)
        #expect(engine.orchardBalance() == Zatoshi.zero)
    }

    @Test func immediateFlowIsSingleForegroundTransfer() async {
        let engine = makeEngine()
        await engine.debugSeed(orchard: Zatoshi(100_000_000), noteCount: 0) // 1 ZEC
        engine.selectMode(.immediate)

        let schedule = await engine.propose()
        #expect(schedule.transfers.count == 1)

        await engine.signAndStore(schedule)
        let result = await engine.executeNext(NetworkPrivacyOptions(useTor: false))
        if case .success = result {
            // expected
        } else {
            Issue.record("expected success, got \(String(describing: result))")
        }
        #expect(engine.currentState() == .complete)
    }

    @Test func armedInvalidNoteRequiresAttentionThenRestart() async {
        let engine = makeEngine()
        await engine.debugSeed(orchard: Zatoshi(1_000_000_000), noteCount: 3)
        engine.selectMode(.privateScheduled)

        let proposal = await engine.prepareSplit()
        _ = await engine.submitSplit(proposal)
        engine.confirmSplit()
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        await engine.debugArm(.invalidNote)
        let result = await engine.executeNext(NetworkPrivacyOptions(useTor: false))
        #expect(result == .invalidNote)
        #expect(engine.invalid())
        if case .requiresAttention(.invalidTransfer) = engine.currentState() {
            // expected
        } else {
            Issue.record("expected requiresAttention(invalidTransfer)")
        }

        let restart = await engine.restart()
        #expect(restart.transfers.count >= 1)
        #expect(engine.currentState() == .readyToPropose)
    }

    @Test func overdueDetectedAfterAdvancingHeight() async {
        let engine = makeEngine()
        await engine.debugSeed(orchard: Zatoshi(1_000_000_000), noteCount: 3)
        engine.selectMode(.privateScheduled)

        let proposal = await engine.prepareSplit()
        _ = await engine.submitSplit(proposal)
        engine.confirmSplit()
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        #expect(!engine.overdue())
        await engine.debugAdvanceHeight(10_000)
        #expect(engine.overdue())
    }

    @Test func jumpToCompleteWithDustLeavesSmallRemainder() async {
        let engine = makeEngine()
        await engine.debugSeed(orchard: Zatoshi(1_000_000_000), noteCount: 3)
        engine.selectMode(.privateScheduled)
        let proposal = await engine.prepareSplit()
        _ = await engine.submitSplit(proposal)
        engine.confirmSplit()
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        await engine.debugJump(.completeWithDust)
        #expect(engine.currentState() == .complete)
        #expect(engine.orchardBalance().amount > 0)
    }
}
