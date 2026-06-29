//
//  DummyMigrationEngineTests.swift
//  zodlTests
//
//  Exercises the simulated migration engine end-to-end.
//

import Testing
import Foundation
import ComposableArchitecture
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

    @Test func prepareSplitProducesThreeToFiveNotesSummingToNet() async {
        let engine = makeEngine()
        await engine.debugSeed(orchard: Zatoshi(1_245_800_000), noteCount: 0) // ≈12.458 ZEC, no override
        engine.selectMode(.privateScheduled)

        let proposal = await engine.prepareSplit()

        #expect((3...5).contains(proposal.outputNotes.count))
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

    @Test func acknowledgeCompletionMarksAndPersistsFlag() async {
        let engine = makeEngine()
        await engine.debugSeed(orchard: Zatoshi(100_000_000), noteCount: 0) // 1 ZEC → single immediate transfer
        engine.selectMode(.immediate)
        await engine.signAndStore(await engine.propose())
        _ = await engine.executeNext(NetworkPrivacyOptions(useTor: false))
        #expect(engine.currentState() == .complete)
        #expect(!engine.isCompletionAcknowledged())

        engine.acknowledgeCompletion()
        #expect(engine.isCompletionAcknowledged())
        // Acknowledgment doesn't change the migration state, only the banner gate.
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

    @Test func networkErrorStallsThenSendNowCompletes() async {
        let engine = makeEngine()
        await engine.debugSeed(orchard: Zatoshi(1_000_000_000), noteCount: 3)
        engine.selectMode(.privateScheduled)
        let proposal = await engine.prepareSplit()
        _ = await engine.submitSplit(proposal)
        engine.confirmSplit()
        await engine.signAndStore(await engine.propose())

        // A network error stalls the migration (it is NOT a silent retry).
        await engine.debugArm(.networkError(retryable: true))
        let stalled = await engine.executeNext(NetworkPrivacyOptions(useTor: false))
        #expect(stalled == .networkError(retryable: true))
        if case .requiresAttention(.transferStalled) = engine.currentState() {
            // expected
        } else {
            Issue.record("expected transferStalled, got \(engine.currentState())")
        }
        #expect(engine.overdue())
        #expect(!engine.invalid())

        // "Send now" (no armed failure) broadcasts the stalled transfer and clears the attention state.
        let sent = await engine.executeNext(NetworkPrivacyOptions(useTor: false))
        if case .success = sent {
            // expected
        } else {
            Issue.record("expected success, got \(String(describing: sent))")
        }
        if case .requiresAttention = engine.currentState() {
            Issue.record("still requiresAttention after send now")
        }
    }

    @Test func rescheduleStalledReturnsToInProgress() async {
        let engine = makeEngine()
        await engine.debugSeed(orchard: Zatoshi(1_000_000_000), noteCount: 3)
        engine.selectMode(.privateScheduled)
        let proposal = await engine.prepareSplit()
        _ = await engine.submitSplit(proposal)
        engine.confirmSplit()
        await engine.signAndStore(await engine.propose())

        await engine.debugArm(.networkError(retryable: true))
        _ = await engine.executeNext(NetworkPrivacyOptions(useTor: false))
        #expect(engine.overdue())

        await engine.rescheduleStalled()
        if case .inProgress = engine.currentState() {
            // expected
        } else {
            Issue.record("expected inProgress after reschedule, got \(engine.currentState())")
        }
        #expect(!engine.overdue())
    }

    @Test func recreateInvalidReplacesOnlyThatTransfer() async {
        let engine = makeEngine()
        await engine.debugSeed(orchard: Zatoshi(1_000_000_000), noteCount: 3)
        engine.selectMode(.privateScheduled)
        let proposal = await engine.prepareSplit()
        _ = await engine.submitSplit(proposal)
        engine.confirmSplit()
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)
        let countBefore = schedule.transfers.count

        await engine.debugArm(.invalidNote)
        _ = await engine.executeNext(NetworkPrivacyOptions(useTor: false))
        #expect(engine.invalid())
        let invalidRow = engine.transferRows().first { $0.status == .invalid }
        #expect(invalidRow != nil)

        await engine.recreateInvalid()
        let rowsAfter = engine.transferRows()
        #expect(rowsAfter.count == countBefore)
        #expect(!rowsAfter.contains { $0.status == .invalid })
        if case .inProgress = engine.currentState() {
            // expected
        } else {
            Issue.record("expected inProgress after recreate, got \(engine.currentState())")
        }
        // The recreated transfer keeps the same amount as the invalid one it replaced.
        if let invalidRow, let recreated = rowsAfter.first(where: { $0.index == invalidRow.index }) {
            #expect(recreated.amount == invalidRow.amount)
        }
    }
}

@Suite(.serialized)
struct MigrationBackgroundWorkerTests {
    /// Regression for the debug "arm Network error → run background task" path: the step must report a
    /// concrete outcome (it changes nothing on screen by design), so the panel can surface it.
    @Test func reportsNothingPendingThenNetworkError() async {
        let store = MigrationStateStore.ephemeral()
        let client = MigrationSDKClient.live(store: store)

        await withDependencies {
            $0.migrationSDK = client
            $0.localNotification.post = { _, _, _ in }
            $0.migrationBGScheduler.scheduleNextRun = { _ in }
            $0.migrationBGScheduler.scheduleNightlyRun = { }
            $0.migrationActivity.lastActivity = { nil }
        } operation: {
            let worker = MigrationBackgroundWorker()

            // No transfers yet → nothing to execute.
            await client.debug.seed(Zatoshi(1_000_000_000), 3)
            let idle = await worker.runMigrationStep(trigger: .scheduledTask)
            #expect(idle == .nothingPending)

            // Commit a schedule, arm a network error, then run: the transfer stays pending and the
            // outcome reports the (silent, retryable) network error.
            client.selectMigrationMode(.privateScheduled)
            let proposal = await client.prepareNoteSplit()
            _ = await client.submitNoteSplit(proposal)
            await client.debug.confirmSplitNow()
            let schedule = await client.proposeMigrationTransfers()
            await client.signAndStoreMigrationSchedule(schedule)

            await client.debug.armNextTransferResult(.networkError(retryable: true))
            let armed = await worker.runMigrationStep(trigger: .scheduledTask)
            #expect(armed == .result(.networkError(retryable: true)))

            // The migration is now visibly stalled (no longer a silent retry) — this is what makes the
            // SmartBanner switch and the Resume Migration screen appear.
            if case .requiresAttention(.transferStalled) = client.getMigrationState() {
                // expected
            } else {
                Issue.record("expected requiresAttention(transferStalled), got \(client.getMigrationState())")
            }
            #expect(client.hasOverdueTransfers())
            #expect(!client.hasInvalidTransfers())
        }
    }

    @Test func recordsRunLogEntriesPerRun() async {
        let client = MigrationSDKClient.live(store: .ephemeral(), runLogStore: .ephemeral())

        await withDependencies {
            $0.migrationSDK = client
            $0.localNotification.post = { _, _, _ in }
            $0.migrationBGScheduler.scheduleNextRun = { _ in }
            $0.migrationBGScheduler.scheduleNightlyRun = { }
            $0.migrationActivity.lastActivity = { nil }
        } operation: {
            let worker = MigrationBackgroundWorker()

            // No schedule yet → the run records a "nothing pending" entry.
            await client.debug.seed(Zatoshi(1_000_000_000), 3)
            _ = await worker.runMigrationStep(trigger: .scheduledTask)
            #expect(client.backgroundRunLog().count == 1)
            #expect(client.backgroundRunLog().first?.outcome == .nothingPending)

            // Commit a schedule, then a run sends transfer 1 and records a "sent" entry (newest first).
            client.selectMigrationMode(.privateScheduled)
            let proposal = await client.prepareNoteSplit()
            _ = await client.submitNoteSplit(proposal)
            await client.debug.confirmSplitNow()
            let schedule = await client.proposeMigrationTransfers()
            await client.signAndStoreMigrationSchedule(schedule)
            _ = await worker.runMigrationStep(trigger: .scheduledTask)

            let log = client.backgroundRunLog()
            #expect(log.count == 2)
            if case .sent = log.first?.outcome {
                // expected
            } else {
                Issue.record("expected newest entry .sent, got \(String(describing: log.first?.outcome))")
            }

            client.clearBackgroundRunLog()
            #expect(client.backgroundRunLog().isEmpty)
        }
    }
}
