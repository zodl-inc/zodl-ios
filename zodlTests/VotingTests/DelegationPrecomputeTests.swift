#if VOTING_ENABLED
//
//  DelegationPrecomputeTests.swift
//  zodlTests
//
//  MOB-1929. A software wallet's authorization proof (ZKP #1) used to start from cold the
//  moment the user tapped Confirm, even though the app had already spent the whole
//  answer-picking phase warming everything around it. These tests pin the extension: the
//  background precompute now also proves each bundle speculatively — with viewing material
//  only, never the seed and never a signature — Confirm promotes the proof already running
//  instead of starting a second one, and the delegation pipeline reuses what was stored.
//
//  Serialized for the same reason as `VotingCoordFlowCoordinatorTests`: the coordinator's
//  State touches process-global `@Shared` storage (`selectedWalletAccount`). The time limit is
//  the backstop for the deadline-free waits these tests use — a wait that never fires is
//  recorded as a failure rather than running until the CI job's own timeout.
//

import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct DelegationPrecomputeTests {
    private let roundId = VotingBatchSubmissionFixture.roundId

    /// The claim the whole change rests on: entering an eligible poll proves every bundle
    /// ahead of Confirm, and does it without ever touching the wallet seed or signing
    /// anything. Nothing about the Confirm screen's own proof state moves.
    @Test func eligibleEntryProvesEveryBundleSpeculativelyWithoutTheSeed() async throws {
        let fixture = makeFixture()
        let store = makeStore(fixture)

        store.send(.maybeStartDelegationPrecompute(roundId: roundId))

        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.delegationPrecomputeStatus == .ready
        }
        // The promotion is armed per run and must not survive it; the reset is the effect's
        // last act, after the completion action it already sent.
        // Two resets bracket a run: one at its start, one from the completion reducer.
        await fixture.recorder.awaitEvents { $0.filter { $0 == "reset-promotion" }.count == 2 }

        let events = fixture.recorder.events()
        #expect(
            events == [
                "reset-promotion", "pczt:0", "pir:0", "specprove:0",
                "pczt:1", "pir:1", "specprove:1",
                "reset-promotion"
            ]
        )
        // Nothing that needs the seed, a signature, or the chain: a speculative proof is
        // viewing material in and a proof out.
        #expect(!events.contains("seed-export"))
        #expect(!events.contains { $0.hasPrefix("prove:") })
        #expect(!events.contains { $0.hasPrefix("sign:") })
        #expect(!events.contains { $0.hasPrefix("deleg-submit:") })

        let session = try #require(store.state.roundCache[roundId])
        // A finished speculative proof is not an authorization: only the pipeline, after the
        // chain confirms, may say `.complete`.
        #expect(session.delegationProofStatus == .notStarted)
        #expect(session.delegationPrecomputeProgress == nil)
    }

    /// Confirm arriving mid-precompute joins the proof that is already running — it promotes
    /// it, waits for it, shows its progress, and then finds it stored rather than proving a
    /// second time.
    @Test func confirmDuringPrecomputePromotesWaitsAndReusesTheStoredProof() async throws {
        let fixture = makeFixture()
        // Bundle 1's proof is held open across the Confirm tap, so the promotion demonstrably
        // lands on a proof that is still running.
        let secondProof = fixture.speculativeProofGate(forBundle: 1)
        let secondProofFinish = fixture.speculativeProofFinishGate(forBundle: 1)
        let store = makeStore(fixture)

        store.send(.maybeStartDelegationPrecompute(roundId: roundId))
        await fixture.recorder.awaitEvent("specprove:1")

        store.send(.submitAllDraftsTapped(roundId: roundId))
        await fixture.waitForStoreState(store) { $0.pendingBatchSubmission }
        await fixture.recorder.awaitEvent("promote")

        let waiting = try #require(store.state.roundCache[roundId])
        #expect(waiting.batchSubmissionStatus == .authorizing)
        #expect(waiting.delegationProofStatus == .generating(progress: 0))

        // Releasing the proof's progress — but not its completion — parks the run at the one
        // point where the precompute's own progress is what the Confirm screen is showing.
        secondProof.open()
        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.delegationProofStatus == .generating(progress: 0.75)
        }
        #expect(store.state.roundCache[roundId]?.delegationPrecomputeProgress == 0.75)

        secondProofFinish.open()
        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.delegationProofStatus == .complete
        }
        // And the batch carried on into the vote loop behind it.
        await fixture.recorder.awaitEvent("commit:0:1")

        let events = fixture.recorder.events()
        // The point of promoting rather than restarting: the interactive prover never runs.
        #expect(!events.contains { $0.hasPrefix("prove:") })
        #expect(
            events.filter { $0.hasPrefix("sign:") || $0.hasPrefix("registration:") } == [
                "sign:0", "registration:0", "sign:1", "registration:1"
            ]
        )
    }

    /// The precompute's progress belongs to the Confirm screen only while a Confirm is waiting
    /// on it. Without one it is bookkeeping, and the authorization proof stays untouched.
    @Test func precomputeProgressOnlyMovesTheConfirmProgressWhileConfirmIsPending() async throws {
        let fixture = makeFixture()
        let store = makeStore(fixture)

        await store.send(.delegationPrecomputeProgress(roundId: roundId, progress: 0.4)).finish()

        let idle = try #require(store.state.roundCache[roundId])
        #expect(idle.delegationPrecomputeProgress == 0.4)
        #expect(idle.delegationProofStatus == .notStarted)

        // With a Confirm parked on the precompute, the same event is what moves the
        // authorization progress the user is watching.
        var pendingState = fixture.makeState()
        pendingState.pendingBatchSubmission = true
        let pendingStore = makeStore(fixture, state: pendingState)
        await pendingStore.send(.delegationPrecomputeProgress(roundId: roundId, progress: 0.6)).finish()

        let pending = try #require(pendingStore.state.roundCache[roundId])
        #expect(pending.delegationPrecomputeProgress == 0.6)
        #expect(pending.delegationProofStatus == .generating(progress: 0.6))
    }

    /// A speculative proof is an optimization, not a dependency: when one bundle's fails, the
    /// precompute reports failure and Confirm proves that bundle interactively — while the
    /// bundle that did finish is still reused from storage.
    @Test func aFailedSpeculativeProofFallsBackToTheInteractiveProof() async throws {
        let fixture = makeFixture()
        fixture.failSpeculativeProof(forBundle: 1)
        let store = makeStore(fixture)

        store.send(.maybeStartDelegationPrecompute(roundId: roundId))
        await fixture.waitForStoreState(store) { state in
            Self.isFailed(state.roundCache[self.roundId]?.delegationPrecomputeStatus)
        }
        #expect(store.state.roundCache[roundId]?.delegationPrecomputeProgress == nil)
        // The failure path arms nothing for the next round either.
        await fixture.recorder.awaitEvents { $0.filter { $0 == "reset-promotion" }.count == 2 }

        store.send(.submitAllDraftsTapped(roundId: roundId))
        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.delegationProofStatus == .complete
        }

        let events = fixture.recorder.events()
        // Only the bundle whose speculative proof died is proved again.
        #expect(events.contains("prove:1"))
        #expect(!events.contains("prove:0"))
        // Bundle 0's stored proof assembled its registration without any proving at all, and
        // did so before the interactive lane was ever entered.
        let registrationIndex = try #require(events.firstIndex(of: "registration:0"))
        let signIndex = try #require(events.firstIndex(of: "sign:0"))
        let proveIndex = try #require(events.firstIndex(of: "prove:1"))
        #expect(signIndex < registrationIndex)
        #expect(registrationIndex < proveIndex)
        // Both bundles ended up registered on chain regardless of which lane proved them.
        #expect(events.contains("van:0"))
        #expect(events.contains("van:1"))
    }

    /// A Confirm that lands in the last instant of a run can arm the shared promotion after
    /// that run's own reset; the next run must therefore start by disarming it.
    @Test func aNewRunDisarmsAnyLeftoverPromotionBeforeItsFirstProof() async throws {
        let fixture = makeFixture()
        let store = makeStore(fixture)

        store.send(.maybeStartDelegationPrecompute(roundId: roundId))
        await fixture.recorder.awaitEvent("specprove:0")

        let events = fixture.recorder.events()
        let resetIndex = try #require(events.firstIndex(of: "reset-promotion"))
        let proofIndex = try #require(events.firstIndex(of: "specprove:0"))
        #expect(resetIndex < proofIndex)
    }

    /// With every proof already stored, the pipeline after Confirm reuses each bundle's
    /// registration without proving; the authorization progress the Confirm screen shows must
    /// still move, one step per bundle, instead of sitting at zero through the chain wait.
    @Test func reusingAStoredProofMovesTheAuthorizationProgress() async throws {
        let fixture = makeFixture()
        let secondSubmit = fixture.delegationSubmitGate(forBundle: 1)
        let store = makeStore(fixture)

        store.send(.maybeStartDelegationPrecompute(roundId: roundId))
        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.delegationPrecomputeStatus == .ready
        }

        store.send(.submitAllDraftsTapped(roundId: roundId))
        await fixture.recorder.awaitEvent("registration:1")
        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.delegationProofStatus == .generating(progress: 1.0)
        }

        secondSubmit.open()
        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.delegationProofStatus == .complete
        }
        #expect(!fixture.recorder.events().contains { $0.hasPrefix("prove:") })
    }

    /// A run can start while a Confirm is already parked (a restart after the round's weight
    /// reloads, for instance); the promotion that Confirm gave the previous run is gone with
    /// it, so the new run promotes itself before its first proof.
    @Test func aRunStartedWhileConfirmIsWaitingPromotesItself() async throws {
        let fixture = makeFixture()
        var pendingState = fixture.makeState()
        pendingState.pendingBatchSubmission = true
        let store = makeStore(fixture, state: pendingState)

        store.send(.maybeStartDelegationPrecompute(roundId: roundId))
        await fixture.recorder.awaitEvent("specprove:0")

        let events = fixture.recorder.events()
        let promoteIndex = try #require(events.firstIndex(of: "promote"))
        let proofIndex = try #require(events.firstIndex(of: "specprove:0"))
        #expect(promoteIndex < proofIndex)
    }

    // MARK: - Helpers

    /// Two bundles over ten notes, one question, nothing proved and nothing precomputed — a
    /// poll the user has just entered.
    private func makeFixture() -> VotingBatchSubmissionFixture {
        VotingBatchSubmissionFixture(proposalCount: 1, bundleCount: 2, delegationProven: false)
    }

    private func makeStore(
        _ fixture: VotingBatchSubmissionFixture,
        state: VotingCoordFlow.State? = nil
    ) -> StoreOf<VotingCoordFlow> {
        Store(initialState: state ?? fixture.makeState()) {
            VotingCoordFlow()
        } withDependencies: {
            fixture.dependencies(&$0)
        }
    }

    private static func isFailed(_ status: DelegationPrecomputeStatus?) -> Bool {
        if case .failed = status {
            return true
        }
        return false
    }
}
#endif
