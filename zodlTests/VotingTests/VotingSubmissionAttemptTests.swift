#if VOTING_ENABLED
import ComposableArchitecture
import Foundation
import os
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZODLSwiftWalletSDK

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct VotingSubmissionAttemptTests {
    private let roundId = VotingBatchSubmissionFixture.roundId

    @Test
    func wallPhasesCoverOneAttemptAndFinishOnlyOnce() {
        let clock = AttemptClock()
        let lines = SignalledRecords<String>()
        let attempt = VotingSubmissionAttempt(roundId: roundId, path: .software, prepared: false, client: clock.client(lines))
        clock.advance(to: 20)
        attempt.enter(.delegation)
        clock.advance(to: 120)
        attempt.enter(.votes)
        clock.advance(to: 220)
        attempt.enter(.sharesJoin)
        clock.advance(to: 250)
        attempt.finish(.completed)
        clock.advance(to: 999)
        attempt.finish(.failed)
        attempt.enter(.delegation)

        #expect(attempt.snapshot() == VotingSubmissionAttempt.Snapshot(
            preparationMs: 20, delegationMs: 100, votesMs: 100, sharesJoinMs: 30, totalMs: 250, outcome: .completed
        ))
        #expect(lines.values.count == 1)
        #expect(lines.values.first?.contains("outcome=completed") == true)
        #expect(lines.values.first?.contains("round=aaaaaaaa") == true)
        #expect(lines.values.first?.contains(roundId) == false)
    }

    @Test
    func concurrentWorkDoesNotInflateWallTime() async {
        let clock = AttemptClock()
        let lines = SignalledRecords<String>()
        let attempt = VotingSubmissionAttempt(roundId: roundId, path: .software, prepared: true, client: clock.client(lines))
        let totals = VotingSubmissionTrace.Totals()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await totals.add("prove", 150) }
            group.addTask { await totals.add("prove", 150) }
        }
        clock.advance(to: 250)
        attempt.finish(.partial)
        let work = await VotingSubmissionTrace.submissionSummary(
            context: "round=aaaaaaaa", bundleCount: 2, questionCount: 1, totalMilliseconds: 250, totals: totals
        )
        #expect(attempt.snapshot().totalMs == 250)
        #expect(work.contains("proveWorkMs=300"))
        #expect(work.contains("scope=votePipelines"))
        #expect(lines.values.first?.contains("outcome=partial") == true)
    }

    @Test
    func coldAndWarmSoftwareAttemptsIncludeOnlyRemainingWork() async throws {
        for warm in [false, true] {
            let clock = AttemptClock()
            let lines = SignalledRecords<String>()
            let fixture = VotingBatchSubmissionFixture(proposalCount: 1, delegationProven: warm)
            let delegation = fixture.delegationSubmitGate(forBundle: 0)
            let proof = fixture.commitGate(forBundle: 0, proposal: 1)
            let store = makeStore(fixture, clock: clock, lines: lines)
            let task = store.send(.authenticationSucceeded(roundId: roundId))
            if !warm {
                await fixture.recorder.awaitEvent("registration:0")
                clock.advance(to: 100)
                delegation.open()
            }
            await fixture.recorder.awaitEvent("sync")
            let attempt = store.state.roundCache[roundId]?.submissionAttempt
            #expect(attempt != nil)
            #expect(attempt?.snapshot().delegationMs == (warm ? 0 : 100))
            clock.advance(to: 250)
            proof.open()
            await task.finish()
            #expect(attempt?.snapshot().totalMs == 250)
            #expect(attempt?.snapshot().outcome == .completed)
            #expect(lines.values.count == 1)
        }
    }

    @Test
    func precomputeWaitAndDuplicateAuthRetainTheOriginalAttempt() async throws {
        for failPrecompute in [false, true] {
            let fixture = VotingBatchSubmissionFixture(proposalCount: 1, delegationProven: false)
            let speculative = fixture.speculativeProofGate(forBundle: 0)
            if failPrecompute { fixture.failSpeculativeProof(forBundle: 0) }
            let clock = AttemptClock()
            let lines = SignalledRecords<String>()
            let store = makeStore(fixture, clock: clock, lines: lines)
            let background = store.send(.maybeStartDelegationPrecompute(roundId: roundId))
            await fixture.recorder.awaitEvent("specprove:0")
            #expect(store.state.roundCache[roundId]?.submissionAttempt == nil)
            clock.advance(to: 1000)
            await store.send(.authenticationSucceeded(roundId: roundId)).finish()
            let attempt = store.state.roundCache[roundId]?.submissionAttempt
            #expect(attempt != nil)
            clock.advance(to: 1120)
            await store.send(.authenticationSucceeded(roundId: roundId)).finish()
            #expect(store.state.roundCache[roundId]?.submissionAttempt == attempt)
            speculative.open()
            await background.finish()
            #expect(attempt?.snapshot().totalMs == 120)
            #expect(attempt?.snapshot().delegationMs == 120)
            #expect(attempt?.snapshot().outcome == .completed)
            #expect(lines.values.count == 1)
            #expect(fixture.recorder.events().filter { $0 == "deleg-submit:0" }.count == 1)
            #expect(fixture.recorder.events().contains("prove:0") == failPrecompute)
        }
    }

    @Test
    func partialFailureRetryAndStaleFinishHaveSeparateIdentities() async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 2)
        fixture.failDelivery(forProposal: 2)
        let clock = AttemptClock()
        let lines = SignalledRecords<String>()
        let store = makeStore(fixture, clock: clock, lines: lines)
        await store.send(.authenticationSucceeded(roundId: roundId)).finish()
        let first = try #require(store.state.roundCache[roundId]?.submissionAttempt)
        #expect(first.snapshot().outcome == .partial)
        #expect(store.state.roundCache[roundId]?.votes[1] == .option(0))
        let proof = fixture.commitGate(forBundle: 0, proposal: 2)
        clock.advance(to: 300)
        let retry = store.send(.retryBatchSubmission(roundId: roundId))
        await fixture.recorder.awaitEvents { $0.filter { $0 == "sync" }.count == 3 }
        let second = try #require(store.state.roundCache[roundId]?.submissionAttempt)
        #expect(first.id != second.id)
        #expect(second.snapshot().totalMs == 0)
        first.finish(.completed)
        await store.send(.submissionAttemptSettled(roundId: roundId, attemptId: first.id, successCount: 1)).finish()
        #expect(!second.isFinished)
        clock.advance(to: 340)
        proof.open()
        await retry.finish()
        #expect(second.snapshot().outcome == .failed)
        #expect(second.snapshot().totalMs == 40)
        #expect(lines.values.count == 2)
    }

    @Test
    func cancellationAndCacheInvalidationFinishOnce() async throws {
        for invalidation in 0..<3 {
            let fixture = VotingBatchSubmissionFixture(proposalCount: 1)
            let delivery = fixture.gate(forProposal: 1)
            let clock = AttemptClock()
            let lines = SignalledRecords<String>()
            let store = makeStore(fixture, clock: clock, lines: lines)
            let submission = store.send(.authenticationSucceeded(roundId: roundId))
            await fixture.recorder.awaitEvent("deliver:1")
            let attempt = store.state.roundCache[roundId]?.submissionAttempt
            #expect(attempt != nil)
            clock.advance(to: 80)
            switch invalidation {
            case 0:
                await store.send(.dismissFlow).finish()
            case 1:
                await store.send(.walletAccountChanged(nil)).finish()
            default:
                submission.cancel()
            }
            delivery.open()
            await submission.finish()
            #expect(attempt?.snapshot().outcome == .cancelled)
            #expect(attempt?.snapshot().totalMs == 80)
            #expect(lines.values.count == 1)
        }
    }

    @Test
    func missingConfigurationClosesAnAttemptInsteadOfLeakingIt() {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 1)
        var state = fixture.makeState()
        state.serviceConfig = nil
        let clock = AttemptClock()
        let lines = SignalledRecords<String>()
        withDependencies {
            $0.votingSubmissionTiming = clock.client(lines)
        } operation: {
            _ = VotingCoordFlow().reduceAuthenticationSucceeded(&state, roundId: roundId)
        }
        #expect(state.roundCache[roundId]?.submissionAttempt?.snapshot().outcome == .failed)
        #expect(lines.values.count == 1)
    }

    @Test(arguments: [false, true])
    func keystoneAutomatedProofHasItsOwnScopeAndContinuesWhenPending(pendingSubmission: Bool) async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 1, delegationProven: false)
        var state = fixture.makeState()
        state.isKeystoneUser = true
        state.pendingBatchSubmission = pendingSubmission
        state.roundCache[roundId]?.batchSubmissionStatus = .authorizing
        let registration = VotingBatchSubmissionFixture.makeDelegationRegistration(bundleIndex: 0)
        state.roundCache[roundId]?.keystoneBundleSignatures = [
            KeystoneBundleSignature(
                bundleIndex: 0, sig: registration.spendAuthSig, sighash: registration.sighash, rk: registration.rk
            )
        ]
        let clock = AttemptClock()
        let lines = SignalledRecords<String>()
        let delegation = fixture.delegationSubmitGate(forBundle: 0)
        let store = Store(initialState: state) { VotingCoordFlow() } withDependencies: {
            fixture.dependencies(&$0)
            $0.votingSubmissionTiming = clock.client(lines)
        }
        clock.advance(to: 1000)
        let task = store.send(.keystoneAllBundlesSigned(roundId: roundId))
        await fixture.recorder.awaitEvent("registration:0")
        let attempt = store.state.roundCache[roundId]?.submissionAttempt
        #expect(attempt != nil)
        let duplicate = store.send(.keystoneAllBundlesSigned(roundId: roundId))
        clock.advance(to: 1120)
        delegation.open()
        await task.finish()
        await duplicate.finish()
        #expect(store.state.roundCache[roundId]?.submissionAttempt == attempt)
        #expect(attempt?.snapshot().totalMs == 120)
        #expect(attempt?.snapshot().delegationMs == 120)
        #expect(attempt?.snapshot().outcome == .completed)
        #expect(fixture.recorder.events().filter { $0 == "prove:0" }.count == 1)
        #expect(lines.values.first?.contains("path=keystone") == true)
        let scope = pendingSubmission ? "scope=automatedSubmission" : "scope=automatedDelegation"
        #expect(lines.values.first?.contains(scope) == true)
        #expect(fixture.recorder.events().contains("commit:0:1") == pendingSubmission)
    }

    @Test
    func confirmationFailureEmitsOneFailedTimingLine() async {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 1)
        let clock = AttemptClock()
        let lines = SignalledRecords<String>()
        let store = Store(initialState: fixture.makeState()) { VotingCoordFlow() } withDependencies: {
            fixture.dependencies(&$0)
            $0.votingSubmissionTiming = clock.client(lines, recordDetails: true)
            $0.votingAPI.fetchTxConfirmation = { _, _, _ in TxConfirmation(height: 100, code: 1) }
        }
        await store.send(.authenticationSucceeded(roundId: roundId)).finish()
        #expect(store.state.roundCache[roundId]?.submissionAttempt?.snapshot().outcome == .failed)
        #expect(lines.values.filter { $0.hasPrefix("Voting trace failed confirm ") }.count == 1)
        #expect(!lines.values.contains { $0.hasPrefix("Voting trace end confirm ") })
    }

    @Test
    func recoveredHelperDeliveryContributesToTheSameAttemptWork() async {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 1)
        let clock = AttemptClock()
        let lines = SignalledRecords<String>()
        let delivery = fixture.gate(forProposal: 1)
        let store = Store(initialState: fixture.makeState()) { VotingCoordFlow() } withDependencies: {
            fixture.dependencies(&$0)
            $0.votingSubmissionTiming = clock.client(lines, recordDetails: true)
            $0.votingCrypto.getVoteTxHash = { _, _, _ in .present("cached-tx") }
        }
        let task = store.send(.authenticationSucceeded(roundId: roundId))
        await fixture.recorder.awaitEvent("deliver:1")
        clock.advance(to: 70)
        delivery.open()
        await task.finish()
        #expect(store.state.roundCache[roundId]?.submissionAttempt?.snapshot().totalMs == 70)
        #expect(lines.values.contains { $0.hasPrefix("Voting trace end deliver ") && $0.contains("ms=70") })
        #expect(lines.values.contains { $0.hasPrefix("Voting submission work summary ") && $0.contains("deliverWorkMs=70") })
        #expect(!fixture.recorder.events().contains("commit:0:1"))
    }

    @Test
    func configResetInvalidatesTheOldAttemptAndStaleSettlementCannotFinishItsReplacement() throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 1)
        var state = fixture.makeState()
        let clock = AttemptClock()
        let lines = SignalledRecords<String>()
        let first = VotingSubmissionAttempt(roundId: roundId, path: .software, prepared: false, client: clock.client(lines))
        state.roundCache[roundId]?.submissionAttempt = first
        state.path.append(.configSettings(VotingConfigSettings.State()))
        let configId = try #require(state.path.ids.last)
        let flow = VotingCoordFlow()
        _ = flow.coordinatorReduce().reduce(into: &state, action: .path(.element(id: configId, action: .configSettings(.delegate(.saved)))))
        #expect(first.snapshot().outcome == .cancelled)
        #expect(state.roundCache.isEmpty)
        let second = VotingSubmissionAttempt(roundId: roundId, path: .software, prepared: true, client: clock.client(lines))
        state.roundCache[roundId] = RoundSession(roundId: roundId)
        state.roundCache[roundId]?.submissionAttempt = second
        state.roundCache[roundId]?.batchSubmissionStatus = .completed(successCount: 1)
        _ = flow.coordinatorReduce().reduce(into: &state, action: .submissionAttemptSettled(roundId: roundId, attemptId: first.id, successCount: 1))
        #expect(!second.isFinished)
        #expect(lines.values.filter { $0.hasPrefix("Voting automated attempt summary") }.count == 1)
    }

    private func makeStore(
        _ fixture: VotingBatchSubmissionFixture,
        clock: AttemptClock,
        lines: SignalledRecords<String>
    ) -> StoreOf<VotingCoordFlow> {
        var state = fixture.makeState()
        state.walletId = "previous-wallet"
        return Store(initialState: state) {
            VotingCoordFlow()
        } withDependencies: {
            fixture.dependencies(&$0)
            $0.votingSubmissionTiming = clock.client(lines)
        }
    }
}

private final class AttemptClock: Sendable {
    private let origin = ContinuousClock().now
    private let offset = OSAllocatedUnfairLock(initialState: Int64(0))

    func advance(to milliseconds: Int64) {
        offset.withLock { $0 = milliseconds }
    }

    func client(_ lines: SignalledRecords<String>, recordDetails: Bool = false) -> VotingSubmissionTimingClient {
        VotingSubmissionTimingClient(
            now: { self.origin.advanced(by: .milliseconds(self.offset.withLock { $0 })) },
            sink: { line in
                if recordDetails || line.hasPrefix("Voting automated attempt summary") { lines.record(line) }
            }
        )
    }
}
#endif
