//
//  MigrationSimulatorEngineTests.swift
//  zodlTests
//
//  Covers `MigrationSimulatorEngine` (MOB-1480): fresh defaults, the full scheduled/immediate
//  lifecycles, due-gating, armed results (invalidNote/expired/networkError incl. stalled slip +
//  reschedule recovery), restart after invalid, passive overdue/expiry time derivation, split
//  sum-exactness/reproducibility, transferRows caption fields, summary/progress math, Keystone
//  PCZT fabrication, the silent-split ordering edge case, the real split-confirm timer, and every
//  preset's `MigrationDerivations` table assertion (spec §5.3). Each test builds its own engine
//  over `.ephemeral()` — no shared/global state -> no `.serialized`.
//

import Testing
import Foundation
@preconcurrency import Combine
@preconcurrency import ZcashLightClientKit
import ComposableArchitecture
@testable import zodl_internal

@Suite struct MigrationSimulatorEngineTests {
    private static let networkPrivacy = MigrationNetworkPrivacyOptions(
        useTor: false,
        submissionEndpoint: LightWalletEndpoint(address: "", port: 0)
    )
    private static let defaultBalance = Zatoshi(1_245_800_000)
    private static let fee = Zatoshi(10_000)
    private static let spacing: TimeInterval = 6 * 3600
    private static let overdueGrace: TimeInterval = 3600
    private static let expiryWindow: TimeInterval = 24 * 3600

    private func makeEngine() -> MigrationSimulatorEngine {
        MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
    }

    // MARK: - Fresh defaults

    @Test func freshEngineSeedsExpectedDefaults() {
        let engine = makeEngine()

        #expect(engine.currentState() == MigrationState.notStarted)
        #expect(engine.orchardBalance() == Self.defaultBalance)
        // Opt-in: a fresh install starts with the simulation OFF (panel toggle turns it on).
        #expect(engine.isActive == false)
        #expect(engine.isNoteSplitNeeded() == true)
        #expect(engine.hasOverdue() == false)
        #expect(engine.hasInvalid() == false)
        #expect(engine.progress() == nil)
    }

    @Test func setActiveTogglesAndReflectsInReadout() {
        let engine = makeEngine()

        engine.setActive(true)

        #expect(engine.isActive == true)
        #expect(engine.readout().isActive == true)

        engine.setActive(false)

        #expect(engine.isActive == false)
        #expect(engine.readout().isActive == false)
    }

    @Test func resetPreservesTheActivationToggle() {
        let engine = makeEngine()
        engine.setActive(true)
        engine.advanceTime(by: 3600)

        engine.reset()

        #expect(engine.isActive == true)
        #expect(engine.readout().timeOffset == 0)
    }

    @Test func resetReturnsToSeededDefault() {
        let engine = makeEngine()
        engine.seed(orchard: Zatoshi(1), noteCount: 1)

        engine.reset()

        #expect(engine.currentState() == MigrationState.notStarted)
        #expect(engine.orchardBalance() == Self.defaultBalance)
    }

    // MARK: - Full scheduled lifecycle

    @Test func fullScheduledLifecycleReachesCompleteWithZeroBalance() async {
        let engine = makeEngine()

        #expect(engine.isNoteSplitNeeded() == true)
        let proposal = await engine.prepareSplit()
        #expect((3...5).contains(proposal.outputNotes.count))
        #expect(proposal.outputNotes.reduce(Zatoshi.zero, +) == Zatoshi(Self.defaultBalance.amount - Self.fee.amount))

        let submitResult = await engine.submitSplit(proposal)
        guard case MigrationTransferResult.success = submitResult else {
            Issue.record("Expected submitSplit to succeed")
            return
        }
        #expect(engine.currentState() == MigrationState.splitPendingConfirmation)

        engine.confirmSplitNow()
        #expect(engine.currentState() == MigrationState.readyToPropose)

        let schedule = await engine.propose()
        #expect(schedule.transfers.count == proposal.outputNotes.count)

        await engine.signAndStore(schedule)
        guard case MigrationState.inProgress(let progressAfterSign) = engine.currentState() else {
            Issue.record("Expected .inProgress after signAndStore")
            return
        }
        #expect(progressAfterSign.totalTransfers == schedule.transfers.count)
        #expect(progressAfterSign.completedTransfers == 0)

        for _ in 0..<schedule.transfers.count {
            engine.makeNextTransferDueNow()
            let result = await engine.executeNext(Self.networkPrivacy)
            guard case MigrationTransferResult.success? = result else {
                Issue.record("Expected executeNext to succeed once due")
                return
            }
        }

        #expect(engine.currentState() == MigrationState.complete)
        #expect(engine.orchardBalance() == Zatoshi.zero)
        #expect(engine.transferRows().allSatisfy { $0.status == .sent })
    }

    // MARK: - Immediate lifecycle

    @Test func immediateLifecycleSingleTransferDueImmediately() async {
        let engine = makeEngine()
        engine.selectMode(MigrationMode.immediate)

        let schedule = await engine.propose()
        #expect(schedule.transfers.count == 1)
        #expect(schedule.transfers[0].amount == Self.defaultBalance)

        await engine.signAndStore(schedule)
        let result = await engine.executeNext(Self.networkPrivacy)
        guard case MigrationTransferResult.success? = result else {
            Issue.record("Expected the single immediate transfer to be due right away")
            return
        }

        #expect(engine.currentState() == MigrationState.complete)
        #expect(engine.orchardBalance() == Zatoshi.zero)
    }

    // MARK: - Due-gating

    @Test func executeNextReturnsNilBeforeDueAndSucceedsAfterAdvancingTime() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.readyToPropose)
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        let before = await engine.executeNext(Self.networkPrivacy)
        #expect(before == nil)
        guard case MigrationState.inProgress(let progressStillPending) = engine.currentState() else {
            Issue.record("Expected state to remain .inProgress when nothing is due")
            return
        }
        #expect(progressStillPending.completedTransfers == 0)

        engine.advanceTime(by: Self.spacing + 1)
        let after = await engine.executeNext(Self.networkPrivacy)
        guard case MigrationTransferResult.success? = after else {
            Issue.record("Expected executeNext to succeed once the first transfer is due")
            return
        }
    }

    @Test func makeNextTransferDueNowForcesImmediateSend() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.readyToPropose)
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)
        #expect(await engine.executeNext(Self.networkPrivacy) == nil)

        engine.makeNextTransferDueNow()
        let result = await engine.executeNext(Self.networkPrivacy)

        guard case MigrationTransferResult.success? = result else {
            Issue.record("Expected success after makeNextTransferDueNow")
            return
        }
    }

    // MARK: - Armed results

    @Test func armedInvalidNoteMarksRowInvalidAndSetsAttentionState() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.readyToPropose)
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        engine.armTransferResult(MigrationTransferResult.invalidNote)
        let result = await engine.executeNext(Self.networkPrivacy)

        #expect(result == MigrationTransferResult.invalidNote)
        guard case MigrationState.requiresAttention(let reason) = engine.currentState(),
              case MigrationAttentionReason.invalidTransfer = reason else {
            Issue.record("Expected .requiresAttention(.invalidTransfer)")
            return
        }
        #expect(engine.hasInvalid() == true)
        #expect(engine.transferRows().contains { $0.status == .invalid })
    }

    @Test func armedExpiredMarksRowExpiredAndSetsAttentionState() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.readyToPropose)
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        engine.armTransferResult(MigrationTransferResult.expired)
        let result = await engine.executeNext(Self.networkPrivacy)

        #expect(result == MigrationTransferResult.expired)
        #expect(engine.currentState() == MigrationState.requiresAttention(MigrationAttentionReason.transferExpired))
        #expect(engine.hasInvalid() == true)
        #expect(engine.transferRows().contains { $0.status == .expired })
    }

    /// MOB-1496: the SDK's `MigrationAttentionReason` has no `.transferStalled` case — an armed
    /// `.networkError` no longer escalates to a literal `.requiresAttention` state; it now just
    /// pushes the transfer's `dueAt` past the overdue grace and leaves `state` as `.inProgress`,
    /// letting `hasOverdue()`'s time math do the signaling (mirrors `MigrationDerivations
    /// .bannerVariant`'s `hasOverdue`-derived `.transferWaiting`). `rescheduleStalled()` was renamed
    /// `rescheduleOverdue()` and now returns the rescheduled `MigrationTransferProposal?`.
    @Test func armedNetworkErrorPushesTransferOverdueAndRescheduleOverdueRecovers() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.readyToPropose)
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        engine.armTransferResult(MigrationTransferResult.networkError(retryable: true))
        let result = await engine.executeNext(Self.networkPrivacy)

        #expect(result == MigrationTransferResult.networkError(retryable: true))
        guard case MigrationState.inProgress = engine.currentState() else {
            Issue.record("Expected .inProgress (armed networkError no longer sets a literal .transferStalled state)")
            return
        }
        #expect(engine.hasOverdue() == true)

        let rescheduled = await engine.rescheduleOverdue()

        #expect(rescheduled != nil)
        guard case MigrationState.inProgress = engine.currentState() else {
            Issue.record("Expected .inProgress after rescheduleOverdue")
            return
        }
        #expect(engine.hasOverdue() == false)
    }

    @Test func armSplitFailureCausesNetworkErrorWithNoStateChange() async {
        let engine = makeEngine()
        let stateBefore = engine.currentState()
        engine.armSplitFailure()

        let proposal = await engine.prepareSplit()
        let result = await engine.submitSplit(proposal)

        #expect(result == MigrationTransferResult.networkError(retryable: true))
        #expect(engine.currentState() == stateBefore)
        #expect(engine.readout().armedResultDescription == nil)
    }

    // MARK: - Restart

    @Test func restartAfterInvalidDropsBrokenRowsAndRebuildsSchedule() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.updatePlanInvalid)
        #expect(engine.hasInvalid() == true)

        let schedule = await engine.restart()

        #expect(engine.currentState() == MigrationState.readyToPropose)
        #expect(engine.hasInvalid() == false)
        #expect(!schedule.transfers.isEmpty)
        // The 2 already-sent transfers are kept (only invalid/expired/pending rows are dropped).
        #expect(engine.transferRows().count == 2)
        #expect(engine.transferRows().allSatisfy { $0.status == .sent })
    }

    // MARK: - Overdue / expiry time derivation

    @Test func overdueDerivesAfterGraceAndExpiryEscalatesAttentionState() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.readyToPropose)
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        #expect(engine.hasOverdue() == false)

        engine.advanceTime(by: Self.spacing + Self.overdueGrace + 1)
        #expect(engine.hasOverdue() == true)
        #expect(engine.transferRows().first?.status == .overdue)

        engine.advanceTime(by: Self.expiryWindow)
        guard case MigrationState.requiresAttention(let reason) = engine.currentState(),
              case MigrationAttentionReason.transferExpired = reason else {
            Issue.record("Expected passive time-based expiry to escalate to .requiresAttention(.transferExpired)")
            return
        }
        #expect(engine.hasInvalid() == true)
    }

    // MARK: - Split sum-exactness and reproducibility

    @Test func splitSumsExactlyToNetAndIsReproducibleForTheDefaultSeed() async {
        let engineA = makeEngine()
        let proposalA = await engineA.prepareSplit()
        let engineB = makeEngine()
        let proposalB = await engineB.prepareSplit()

        #expect(proposalA.outputNotes.reduce(Zatoshi.zero, +) == Zatoshi(Self.defaultBalance.amount - Self.fee.amount))
        #expect(proposalA.outputNotes == proposalB.outputNotes)
    }

    @Test func seedWithExplicitNoteCountIsReproducibleAndSumsExactly() async {
        let engineA = makeEngine()
        engineA.seed(orchard: Zatoshi(500_000_000), noteCount: 4)
        let scheduleA = await engineA.propose()

        let engineB = makeEngine()
        engineB.seed(orchard: Zatoshi(500_000_000), noteCount: 4)
        let scheduleB = await engineB.propose()

        #expect(scheduleA.transfers.count == 4)
        #expect(scheduleA.transfers.map { $0.amount } == scheduleB.transfers.map { $0.amount })
        #expect(scheduleA.transfers.reduce(Zatoshi.zero) { $0 + $1.amount } == Zatoshi(500_000_000 - 10_000))
    }

    // MARK: - transferRows caption fields

    @Test func transferRowsCaptionFieldsMatchActivePendingAndSentSemantics() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.readyToPropose)
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        let initialRows = engine.transferRows()
        #expect(initialRows[0].status == .active)
        // First transfer is due `firstTransferDelay` (~10 min) out — rounds to 0 hours.
        #expect(initialRows[0].hoursFromNow == 0)
        #expect(initialRows[0].sentMinutesAgo == nil)
        #expect(initialRows[0].isBroadcasting == false)
        #expect(initialRows[1].status == .pending)
        // Second transfer is one 6 h spacing after the first (10 min + 6 h rounds to 6).
        #expect(initialRows[1].hoursFromNow == 6)

        engine.makeNextTransferDueNow()
        _ = await engine.executeNext(Self.networkPrivacy)

        let afterSendRows = engine.transferRows()
        #expect(afterSendRows[0].status == .sent)
        #expect(afterSendRows[0].sentMinutesAgo == 0)
        #expect(afterSendRows[0].hoursFromNow == 0)
    }

    // MARK: - Summary / progress math

    @Test func summaryAndProgressMathTracksSentAndRemaining() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.inProgress)

        let summary = engine.summary()
        #expect(summary.transfersTotal == 5)
        #expect(summary.transfersSent == 2)
        #expect(summary.dust == Zatoshi.zero)

        let progress = engine.progress()
        #expect(progress?.completedTransfers == 2)
        #expect(progress?.totalTransfers == 5)

        // MOB-1480: supersedes spec §9 flag #1 as an improvement — `nextTransferReadyAtHeight` now
        // carries the synthetic height of the next unsent transfer (index 2 of 5) instead of nil.
        guard let nextReadyAtHeight = progress?.nextTransferReadyAtHeight else {
            Issue.record("Expected nextTransferReadyAtHeight to carry the next unsent transfer's synthetic height")
            return
        }
        #expect(MigrationSimulatorEngineDerivations.isSyntheticHeight(nextReadyAtHeight) == true)
        let expectedDueAt = Date().addingTimeInterval(Self.spacing * 3)
        let actualTimestamp = MigrationSimulatorEngineDerivations.timestamp(forSyntheticHeight: nextReadyAtHeight)
        #expect(abs(actualTimestamp - expectedDueAt.timeIntervalSince1970) < 5)
    }

    // MARK: - isNextTransferDue

    @Test func isNextTransferDueFalseUntilEarliestUnsentTransferMatures() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.readyToPropose)
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        #expect(engine.isNextTransferDue() == false)

        engine.advanceTime(by: Self.spacing + 1)
        #expect(engine.isNextTransferDue() == true)
    }

    @Test func isNextTransferDueFalseOutsideInProgressState() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.freshRequired)

        #expect(engine.isNextTransferDue() == false)

        engine.applyPreset(SimulatorPreset.complete)
        #expect(engine.isNextTransferDue() == false)
    }

    // MARK: - propose() synthetic heights (MOB-1480, supersedes spec §9.1 as an improvement)

    @Test func proposeStampsSyntheticHeightsMatchingSignAndStoreDueAt() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.readyToPropose)

        let schedule = await engine.propose()
        guard let first = schedule.transfers.first else {
            Issue.record("Expected at least one proposed transfer")
            return
        }

        #expect(MigrationSimulatorEngineDerivations.isSyntheticHeight(first.anchorHeight) == true)
        #expect(first.anchorHeight == first.nextExecutableAfterHeight)
        #expect(first.expiryHeight == first.nextExecutableAfterHeight + 86_400)

        // The height propose() stamped must agree (within a 1s truncation tolerance — each call
        // reads its own `Date()`) with the dueAt signAndStore() actually seeds: the whole point of
        // sharing `MigrationSimulatorEngineDerivations.dueAt`.
        await engine.signAndStore(schedule)
        guard let nextReadyAtHeight = engine.progress()?.nextTransferReadyAtHeight else {
            Issue.record("Expected .inProgress after signAndStore, with a non-nil nextTransferReadyAtHeight")
            return
        }
        #expect(abs(nextReadyAtHeight - first.nextExecutableAfterHeight) <= 1)
    }

    @Test func proposeImmediateStampsHeightDueNow() async {
        let engine = makeEngine()
        engine.selectMode(MigrationMode.immediate)

        let schedule = await engine.propose()
        guard let only = schedule.transfers.first else {
            Issue.record("Expected exactly one proposed transfer for immediate mode")
            return
        }

        let nowHeight = MigrationSimulatorEngineDerivations.syntheticHeight(for: Date())
        #expect(abs(only.nextExecutableAfterHeight - nowHeight) <= 2)
    }

    // MARK: - propose() pre-split preview + cadence (MOB-1480 QA fixes)

    @Test func proposeScheduledBeforeSplitPreviewsTheEventualSplit() async {
        // Fresh scheduled wallet: the split hasn't run yet (it runs silently under the plan's
        // Confirm CTA), but the plan must already show the full 3-5 transfer schedule the split
        // will produce — not one monolithic transfer.
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.freshRequired)

        let schedule = await engine.propose()
        #expect((3...5).contains(schedule.transfers.count))

        // `splitNotes` is pure in (net, seed), so the preview and the actual split at confirm
        // must yield the exact same notes, in order.
        let proposal = await engine.prepareSplit()
        #expect(schedule.transfers.map(\.amount) == proposal.outputNotes)
    }

    @Test func scheduledCadencePutsFirstTransferTenMinutesOutThenSixHourly() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        let first = MigrationSimulatorEngineDerivations.dueAt(forTransferAt: 0, isImmediate: false, now: now)
        let second = MigrationSimulatorEngineDerivations.dueAt(forTransferAt: 1, isImmediate: false, now: now)

        #expect(first == now.addingTimeInterval(10 * 60))
        #expect(second == now.addingTimeInterval(10 * 60 + 6 * 3600))

        #expect(MigrationSimulatorEngineDerivations.scheduleDurationHours(transferCount: 0) == 0)
        #expect(MigrationSimulatorEngineDerivations.scheduleDurationHours(transferCount: 1) == 1)
        // 10 min + 4 spacings of 6 h, rounded up to whole hours.
        #expect(MigrationSimulatorEngineDerivations.scheduleDurationHours(transferCount: 5) == 25)
    }

    // MARK: - Keystone (PCZT)

    @Test func fabricatedPCZTsAreDeterministicAndNonEmpty() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.readyToPropose)
        let schedule = await engine.propose()

        let batchA = engine.fabricateMigrationPCZTs(schedule)
        let batchB = engine.fabricateMigrationPCZTs(schedule)

        #expect(batchA == batchB)
        #expect(batchA.allSatisfy { !$0.pczt.isEmpty })
        #expect(!engine.fabricateNoteSplitPCZT().isEmpty)
    }

    @Test func storeSignedBatchRecordsCount() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.readyToPropose)
        let schedule = await engine.propose()
        // storeSignedBatch takes the SIGNED counterpart — fabricateMigrationPCZTs only produces the
        // unsigned side; "sign" them by re-wrapping each id/pczt pair (this test only cares about
        // the count, not real signing).
        let unsigned = engine.fabricateMigrationPCZTs(schedule)
        let signed = unsigned.map { MigrationSignedTransferPczt(id: $0.id, pczt: $0.pczt) }

        engine.storeSignedBatch(signed)

        #expect(engine.readout().signedBatchCount == signed.count)
    }

    @Test func submitSignedSplitAppliesSameDeterministicSplitAsPrepareSplit() async {
        let engine = makeEngine()
        let expectedProposal = await engine.prepareSplit()

        let pczt = engine.fabricateNoteSplitPCZT()
        let result = await engine.submitSignedSplit(pczt)

        guard case MigrationTransferResult.success = result else {
            Issue.record("Expected success from submitSignedSplit")
            return
        }
        #expect(engine.currentState() == MigrationState.splitPendingConfirmation)

        engine.confirmSplitNow()
        let schedule = await engine.propose()
        #expect(schedule.transfers.map { $0.amount } == expectedProposal.outputNotes)
    }

    // MARK: - Silent-split ordering + real split-confirm timer

    @Test func signAndStoreDuringSplitPendingConfirmationMovesToInProgress() async {
        let engine = makeEngine()
        let proposal = await engine.prepareSplit()
        _ = await engine.submitSplit(proposal)
        #expect(engine.currentState() == MigrationState.splitPendingConfirmation)

        let schedule = await engine.propose()
        await engine.signAndStore(schedule)

        guard case MigrationState.inProgress = engine.currentState() else {
            Issue.record("Expected .inProgress immediately after signAndStore, even without an explicit confirm")
            return
        }
    }

    @Test func staleSplitConfirmTaskNoOpsAfterSignAndStoreAlreadyMovedPastIt() async throws {
        let engine = makeEngine()
        let proposal = await engine.prepareSplit()
        _ = await engine.submitSplit(proposal)
        let schedule = await engine.propose()
        await engine.signAndStore(schedule)
        guard case MigrationState.inProgress = engine.currentState() else {
            Issue.record("Expected .inProgress after signAndStore")
            return
        }

        try await Task.sleep(for: .seconds(15.5))

        guard case MigrationState.inProgress = engine.currentState() else {
            Issue.record("Stale split-confirm task must not revert .inProgress back to .readyToPropose")
            return
        }
    }

    @Test func splitConfirmTaskFlipsToReadyToProposeAfterRealDelay() async throws {
        let engine = makeEngine()
        let proposal = await engine.prepareSplit()
        _ = await engine.submitSplit(proposal)
        #expect(engine.currentState() == MigrationState.splitPendingConfirmation)

        // Poll rather than sleep-once-then-check: under a fully parallel test-suite run the
        // Swift concurrency thread pool can be saturated enough to delay the confirm task's
        // firing well past the nominal 15s delay. Polling for up to 45s tolerates that
        // scheduling jitter while still failing if the timer is genuinely broken.
        var reachedReadyToPropose = false
        for _ in 0..<90 {
            try await Task.sleep(for: .milliseconds(500))
            if engine.currentState() == MigrationState.readyToPropose {
                reachedReadyToPropose = true
                break
            }
        }

        #expect(reachedReadyToPropose == true)
    }

    // MARK: - State stream

    @Test func statePublisherEmitsOnStateChange() {
        let engine = makeEngine()
        let collected = LockIsolated<[MigrationState]>([])
        let cancellable = engine.statePublisher().sink { state in
            collected.withValue { $0.append(state) }
        }

        engine.applyPreset(SimulatorPreset.splitting)
        engine.confirmSplitNow()

        #expect(collected.value.contains(MigrationState.splitPendingConfirmation))
        #expect(collected.value.contains(MigrationState.readyToPropose))
        cancellable.cancel()
    }

    // MARK: - Presets vs. MigrationDerivations (spec §5.3 table)

    @Test func freshRequiredPresetMatchesDerivationTable() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.freshRequired)

        #expect(bannerVariant(for: engine) == MigrationBannerVariant.required)
        #expect(reentryRoute(for: engine) == MigrationReentryRoute.entry)
    }

    @Test func splittingPresetMatchesDerivationTable() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.splitting)

        #expect(bannerVariant(for: engine) == MigrationBannerVariant.splitting)
        #expect(reentryRoute(for: engine) == MigrationReentryRoute.noteSplitProgress)
    }

    @Test func readyToProposePresetMatchesDerivationTable() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.readyToPropose)

        #expect(bannerVariant(for: engine) == MigrationBannerVariant.required)
        #expect(reentryRoute(for: engine) == MigrationReentryRoute.entry)
    }

    @Test func inProgressPresetMatchesDerivationTable() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.inProgress)

        #expect(bannerVariant(for: engine) == MigrationBannerVariant.inProgress(done: 2, total: 5))
        #expect(reentryRoute(for: engine) == MigrationReentryRoute.statusProgress)
    }

    @Test func transferReadyManualPresetMatchesDerivationTable() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.transferReadyManual)
        #expect(SimulatorPreset.transferReadyManual.requiresManualDelivery == true)

        let isNextTransferDue = engine.transferRows().first { $0.status != .sent }?.hoursFromNow == 0
        #expect(isNextTransferDue == true)

        #expect(
            bannerVariant(for: engine, isManualDelivery: true, isNextTransferDue: isNextTransferDue)
                == MigrationBannerVariant.transferReady(number: 3)
        )
        #expect(
            reentryRoute(for: engine, isManualDelivery: true, isNextTransferDue: isNextTransferDue)
                == MigrationReentryRoute.reviewManual(step: 3, total: 5)
        )
    }

    @Test func transferStalledPresetMatchesDerivationTable() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.transferStalled)

        #expect(bannerVariant(for: engine) == MigrationBannerVariant.transferWaiting(number: 3))
        #expect(reentryRoute(for: engine) == MigrationReentryRoute.statusResume)
    }

    @Test func updatePlanInvalidPresetMatchesDerivationTable() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.updatePlanInvalid)

        #expect(bannerVariant(for: engine) == MigrationBannerVariant.updatePlan)
        #expect(reentryRoute(for: engine) == MigrationReentryRoute.recovery(isExpired: false))
    }

    @Test func transfersExpiredPresetMatchesDerivationTable() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.transfersExpired)

        #expect(bannerVariant(for: engine) == MigrationBannerVariant.transfersExpired(first: 3, last: 3))
        #expect(reentryRoute(for: engine) == MigrationReentryRoute.recovery(isExpired: true))
    }

    @Test func syncRequiredPresetMatchesDerivationTableAndSetsEngineFlag() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.syncRequired)

        #expect(engine.isSyncRequired() == true)
        #expect(bannerVariant(for: engine) == MigrationBannerVariant.inProgress(done: 2, total: 5))
        #expect(reentryRoute(for: engine) == MigrationReentryRoute.statusProgress)
    }

    @Test func completePresetMatchesDerivationTable() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.complete)

        #expect(engine.orchardBalance() == Zatoshi.zero)
        #expect(bannerVariant(for: engine) == MigrationBannerVariant.complete)
        #expect(reentryRoute(for: engine) == MigrationReentryRoute.complete)
    }

    @Test func completeWithDustPresetMatchesDerivationTableAndLeavesDust() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.completeWithDust)

        #expect(engine.orchardBalance() == Zatoshi(800_000))
        #expect(engine.summary().dust == Zatoshi(800_000))
        #expect(bannerVariant(for: engine) == MigrationBannerVariant.complete)
        #expect(reentryRoute(for: engine) == MigrationReentryRoute.complete)
    }

    // MARK: - Dust resolution (MOB-1487)

    @Test func lockDustWithDustPresentLocksAndLeavesDustAmountReadable() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.completeWithDust)

        engine.lockDust()

        #expect(engine.isDustLocked() == true)
        #expect(engine.readout().dustRemainder == Zatoshi(800_000))
        #expect(engine.summary().dust == Zatoshi(800_000))
    }

    @Test func lockDustWithNoDustLeavesItUnlocked() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.complete)

        engine.lockDust()

        #expect(engine.isDustLocked() == false)
    }

    @Test func migrateDustWithUnlockedDustSucceedsAndZeroesBalance() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.completeWithDust)

        let result = await engine.migrateDust()

        guard case MigrationTransferResult.success? = result else {
            Issue.record("Expected migrateDust to succeed with unlocked dust present")
            return
        }
        #expect(engine.readout().dustRemainder == Zatoshi.zero)
        #expect(engine.orchardBalance() == Zatoshi.zero)
    }

    @Test func migrateDustAfterLockDustReturnsNilAndLeavesDustUnchanged() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.completeWithDust)
        engine.lockDust()

        let result = await engine.migrateDust()

        #expect(result == nil)
        #expect(engine.readout().dustRemainder == Zatoshi(800_000))
    }

    @Test func migrateDustWithNoDustReturnsNil() async {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.complete)

        let result = await engine.migrateDust()

        #expect(result == nil)
    }

    @Test func applyPresetResetsAPreviouslyLockedDust() {
        let engine = makeEngine()
        engine.applyPreset(SimulatorPreset.completeWithDust)
        engine.lockDust()
        #expect(engine.isDustLocked() == true)

        engine.applyPreset(SimulatorPreset.completeWithDust)

        #expect(engine.isDustLocked() == false)
    }

    // MARK: - Derivation-table helpers

    private func bannerVariant(
        for engine: MigrationSimulatorEngine,
        isManualDelivery: Bool = false,
        isNextTransferDue: Bool = false
    ) -> MigrationBannerVariant? {
        MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: engine.currentState(),
            hasInvalid: engine.hasInvalid(),
            hasOverdue: engine.hasOverdue(),
            isManualDelivery: isManualDelivery,
            isNextTransferDue: isNextTransferDue,
            orchardBalance: engine.orchardBalance(),
            isCompleteAcknowledged: false,
            transferRows: engine.transferRows()
        )
    }

    private func reentryRoute(
        for engine: MigrationSimulatorEngine,
        isManualDelivery: Bool = false,
        isNextTransferDue: Bool = false
    ) -> MigrationReentryRoute {
        MigrationDerivations.reentryRoute(
            isIronwoodActivated: true,
            state: engine.currentState(),
            hasInvalid: engine.hasInvalid(),
            hasOverdue: engine.hasOverdue(),
            isManualDelivery: isManualDelivery,
            isNextTransferDue: isNextTransferDue,
            isCompleteAcknowledged: false,
            progress: engine.progress()
        )
    }
}
