#if VOTING_ENABLED
import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

extension VotingSharedStateSuites {
    /// The outcomes the abandoned 3.1 optimization stack delivered, asserted
    /// against the SDK-driven flow that replaced it.
    ///
    /// Nothing here is a port of that stack's code — the code those optimizations
    /// changed no longer exists. Each row is an outcome a voter can observe: a
    /// delegation proof that is computed once, a ballot that a transaction hash
    /// alone never calls done, a session that stops when the wallet or the route
    /// changes, an error whose own kind decides whether the flow tries again, and
    /// a Keystone loop that asks for one bundle at a time.
    ///
    /// Serialized within itself, and nested under a serialized parent so it
    /// cannot interleave with the coordinator suite: both write the same
    /// process-global `@Shared` values.
    @Suite(.serialized) struct VotingParityTests: VotingTestSuite {
        // MARK: - P1 Delegation proofs are computed once and reused

        /// Every bundle that owes delegation work is proved once while the voter is
        /// still reading the ballot, and Confirm proves nothing again: the run joins
        /// the session the warm-up used and reuses what the crate persisted.
        ///
        /// The plan handed to Confirm still names both bundles as owing delegation
        /// work, so a flow that had warmed nothing — or that warmed per entry rather
        /// than per bundle — would prove here. The run's own report is what says the
        /// proofs were reused: its plan carries both bundles as `signed`.
        @MainActor
        @Test func precomputeProvesEachBundleOnceAndConfirmReusesIt() async throws {
            let recorder = EventRecorder()
            let report = try runReport(
                kind: "no_work_left",
                completedProposals: 2,
                totalProposals: 2,
                completedChoices: [(1, 0), (2, 1)],
                bundlePhases: ["signed", "signed"]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(
                        needsBundleSetup: call == 1,
                        openProposals: [1, 2],
                        delegationBundlesNeedingWork: [0, 1],
                        bundlePhases: ["prepared", "prepared"]
                    )
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 2, eligibleWeight: 100_000_000) }
                $0.votingCrypto.precomputeDelegationProof = { _, bundleIndex in
                    recorder.record("precompute:\(bundleIndex)")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingDelegationProofEvent.finished(
                            bundleIndex == 0 ? VotingDelegationProofStatus.generated : VotingDelegationProofStatus.reused
                        ))
                        continuation.finish()
                    }
                }
                $0.votingCrypto.setBallotIntents = { _, _ in
                    try self.plan(
                        allDecided: true,
                        delegationBundlesNeedingWork: [0, 1],
                        bundlePhases: ["prepared", "prepared"]
                    )
                }
                $0.votingCrypto.runRound = { _, _, _ in
                    recorder.record("runRound")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.precomputeStatus[1] != nil }

            #expect(recorder.events().filter { $0.hasPrefix("precompute:") } == ["precompute:0", "precompute:1"])
            #expect(
                tryUnwrap(store.state.roundCache[activeRoundId]).precomputeStatus == [
                    0: VotingDelegationProofStatus.generated,
                    1: VotingDelegationProofStatus.reused
                ]
            )

            recorder.record("confirmTapped")
            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2)
            }

            let afterConfirm = recorder.events().drop { $0 != "confirmTapped" }
            #expect(
                !afterConfirm.contains { $0.hasPrefix("precompute:") },
                "Confirm must reuse the warmed proofs rather than start another one"
            )
            #expect(recorder.events().filter { $0 == "runRound" } == ["runRound"])
            let session = tryUnwrap(store.state.roundCache[activeRoundId])
            #expect(session.roundPlan?.delegationStatuses.map(\.phase) == [.signed, .signed])
            #expect(session.votes == [1: .option(0), 2: .option(1)])
        }

        // MARK: - P2 A chain hash never completes a ballot; the share hand-off does

        /// A confirmed transaction hash is not a cast ballot.
        ///
        /// The first run reaches the chain and its report carries a confirmed
        /// transaction hash, but it stopped on a failure: nothing is marked voted,
        /// no record is written and no share tracking starts. The retry's report
        /// carries the same hash and stops at `backgroundShareWorkOnly` — the
        /// hand-off — and it is *that*, with the run's own tally, that completes the
        /// ballot and starts the tracking pass.
        ///
        /// Helper confirmation is not blocking: the ballot is cast by then, so the
        /// batch reaches its terminal state at the hand-off and it is the round's
        /// share state that waits for `allConfirmed`.
        @MainActor
        @Test func aChainHashNeverCompletesTheBallotAndTheHandoffStartsShareTracking() async throws {
            let recorder = EventRecorder()
            let gate = TestGate()
            let transactionHash = String(repeating: "7c", count: 32)
            let stoppedOnAFailure = try runReport(
                kind: "failures",
                completedProposals: 1,
                totalProposals: 2,
                confirmedTransactionHash: transactionHash,
                failures: [(kind: "invalid_input", message: "the second bundle's ballot was refused")]
            )
            let reachedTheShareHandoff = try runReport(
                kind: "background_share_work_only",
                completedProposals: 2,
                totalProposals: 2,
                completedChoices: [(1, 0), (2, 1)],
                confirmedTransactionHash: transactionHash
            )
            let passStarted = try shareTrackingEvent(kind: "pass_started", pass: 1)
            let allConfirmed = try shareTrackingReport(kind: "all_confirmed")
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.setBallotIntents = { _, _ in try self.plan(allDecided: true) }
                $0.votingCrypto.runRound = { _, _, _ in
                    let call = recorder.recordAndCount("runRound")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(
                            call == 1 ? stoppedOnAFailure : reachedTheShareHandoff
                        ))
                        continuation.finish()
                    }
                }
                $0.votingCrypto.trackShares = { _, _ in
                    recorder.record("trackShares")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingShareTrackingRunEvent.event(passStarted))
                        let task = Task {
                            // Parked where a real pass waits on its helpers, so the
                            // round is judged while the shares are still in flight.
                            await gate.wait()
                            continuation.yield(VotingShareTrackingRunEvent.finished(allConfirmed))
                            continuation.finish()
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus.isFailureState == true }

            let afterTheHash = tryUnwrap(store.state.roundCache[activeRoundId])
            #expect(afterTheHash.votes.isEmpty, "a confirmed transaction hash marks no proposal voted")
            #expect(afterTheHash.draftVotes == [1: .option(0), 2: .option(1)])
            #expect(afterTheHash.voteRecord == nil)
            #expect(store.state.voteRecords.isEmpty)
            #expect(!recorder.events().contains("trackShares"), "a hash is not a hand-off")

            store.send(.retryBatchSubmission(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.shareTrackingStatus == .tracking(pass: 1) }

            let atTheHandoff = tryUnwrap(store.state.roundCache[activeRoundId])
            #expect(atTheHandoff.batchSubmissionStatus == .completed(successCount: 2))
            #expect(atTheHandoff.votes == [1: .option(0), 2: .option(1)])
            #expect(atTheHandoff.isTrackingShares)

            await gate.open()
            await waitForStore { store.state.roundCache[self.activeRoundId]?.shareTrackingStatus == .confirmed }

            #expect(recorder.events().filter { $0 == "trackShares" } == ["trackShares"])
            #expect(recorder.events().filter { $0 == "runRound" }.count == 2)
        }

        // MARK: - P3 Drain before wipe: an account switch during a live run

        /// A run that is still driving when the wallet changes is stopped in the one
        /// order that does not lose what it has already done: the epoch moves first,
        /// the round's passes are cancelled, and only then is the session closed and
        /// waited on. What the run reports afterwards belongs to a wallet the flow
        /// has left, so it is dropped rather than written back.
        ///
        /// The Root half of this row — the drain completing before the sidecar is
        /// deleted — is `RootInitializeSDKHealTests`.
        @MainActor
        @Test func anAccountSwitchDuringARunCancelsBeforeClosingAndDropsTheLateReport() async throws {
            let recorder = EventRecorder()
            let metadata = VotingMetadataBox()
            let gate = TestGate()
            let report = try runReport(
                kind: "no_work_left",
                completedProposals: 2,
                totalProposals: 2,
                completedChoices: [(1, 0), (2, 1)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingMetadata = self.votingMetadataClient(metadata)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.setBallotIntents = { _, _ in try self.plan(allDecided: true) }
                $0.votingCrypto.setOperationEpoch = { roundId, epoch in
                    recorder.record("setOperationEpoch:\(roundId):\(epoch)")
                }
                $0.votingCrypto.cancelRoundSession = { roundId in recorder.record("cancelRoundSession:\(roundId)") }
                $0.votingCrypto.closeRoundSession = { roundId in recorder.record("closeRoundSession:\(roundId)") }
                $0.votingCrypto.runRound = { _, _, _ in
                    recorder.record("runRound")
                    return AsyncThrowingStream { continuation in
                        let task = Task {
                            // The run is still driving when the wallet changes.
                            await gate.wait()
                            continuation.yield(VotingRoundRunEvent.finished(report))
                            continuation.finish()
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    }
                }
                // The switch re-initializes for the account it lands on. This test is
                // about the run it leaves behind, so that fetch is refused rather than
                // stubbed into a second round load.
                $0.votingAPI.fetchServiceConfig = { _ in throw VotingError(kind: .other, message: "no config in this test") }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }
            let openedEpoch = try #require(store.state.roundCache[activeRoundId]?.sessionEpoch)

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { recorder.events().contains("runRound") }
            #expect(store.state.roundCache[self.activeRoundId]?.isSubmittingVote == true)

            store.send(.walletAccountChanged(keystoneWalletAccount()))
            await waitForStore { recorder.events().contains("closeRoundSession:\(self.activeRoundId)") }

            #expect(
                recorder.events().filter { Self.isSessionLifecycleEvent($0) } == [
                    "setOperationEpoch:\(activeRoundId):\(openedEpoch + 1)",
                    "cancelRoundSession:\(activeRoundId)",
                    "closeRoundSession:\(activeRoundId)"
                ]
            )
            #expect(store.state.roundCache[activeRoundId] == nil)

            // The run wakes up with the wallet already gone. Its consumer was
            // cancelled with the switch, so the report is delivered here the way the
            // stream would have delivered it, and awaited to completion so the
            // decision and any write it would have handed on have run.
            await gate.open()
            await store.send(.roundRunEvent(roundId: activeRoundId, epoch: openedEpoch, event: .finished(report))).finish()

            #expect(store.state.roundCache[activeRoundId] == nil, "a late report must not resurrect the round")
            #expect(store.state.voteRecords.isEmpty)
            #expect(metadata.records.isEmpty)
        }

        // MARK: - P4 A route change reopens on the new route and never falls back

        /// A session's transport is fixed when it is opened, so a wallet that turns
        /// Tor on mid-round loses the sessions it has and the next entry asks for
        /// `.tor`. A Tor route the SDK cannot serve fails the entry with Tor's own
        /// message: there is no `.direct` open to fall back to, because a session on
        /// a route the voter did not choose is the failure, not the fix.
        @MainActor
        @Test func aRouteChangeReopensOnTorAndNeverFallsBackToDirect() async throws {
            let recorder = EventRecorder()
            let initialState = sessionFlowState()
            let swapAPIAccess = initialState.$swapAPIAccess
            let store = Store(initialState: initialState) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.openRoundSession = { _, _, route, epoch in
                    recorder.record("openRoundSession:\(route):\(epoch)")
                    guard route == VotingTransportRoute.tor else { return }
                    throw ZcashError.torClientUnavailable
                }
                $0.votingCrypto.setOperationEpoch = { roundId, epoch in
                    recorder.record("setOperationEpoch:\(roundId):\(epoch)")
                }
                $0.votingCrypto.cancelRoundSession = { roundId in recorder.record("cancelRoundSession:\(roundId)") }
                $0.votingCrypto.closeRoundSession = { roundId in recorder.record("closeRoundSession:\(roundId)") }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            swapAPIAccess.withLock { $0 = .protected }
            await waitForStore { recorder.events().contains("closeRoundSession:\(self.activeRoundId)") }

            #expect(
                recorder.events().filter { Self.isSessionLifecycleEvent($0) } == [
                    "setOperationEpoch:\(activeRoundId):2",
                    "cancelRoundSession:\(activeRoundId)",
                    "closeRoundSession:\(activeRoundId)"
                ]
            )
            #expect(store.state.openRoundSessionIds.isEmpty)

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore {
                store.state.rootScreen == .error(String(localizable: .migrationFailureTorFirstRunBody))
            }

            #expect(
                recorder.events().filter { $0.hasPrefix("openRoundSession") }
                    == ["openRoundSession:direct:1", "openRoundSession:tor:3"]
            )
            #expect(store.state.path.isEmpty)
        }

        // MARK: - P5 The error's own kind decides whether the flow tries again

        /// A run that could not start says why in the crate's own terms, and the
        /// answer is `retryable` rather than anything this side infers: a busy
        /// session is waited out and driven again, and a refused request is shown to
        /// the voter with nothing scheduled behind it.
        ///
        /// The failed call committed no vote, which is what `.authorizationFailed`
        /// means in this flow — `.submissionFailed` would claim a partly cast
        /// ballot — and the voter's own Try again is still on it.
        @MainActor
        @Test func aRetryableRunErrorIsDrivenAgainAndARefusedOneIsNot() async throws {
            let recorder = EventRecorder()
            let sleeps = LockIsolated<[Swift.Duration]>([])
            let report = try runReport(
                kind: "no_work_left",
                completedProposals: 2,
                totalProposals: 2,
                completedChoices: [(1, 0), (2, 1)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.continuousClock = RecordingImmediateClock(sleeps: sleeps)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.setBallotIntents = { _, _ in try self.plan(allDecided: true) }
                $0.votingCrypto.runRound = { _, _, _ in
                    let call = recorder.recordAndCount("runRound")
                    return AsyncThrowingStream { continuation in
                        guard call > 1 else {
                            continuation.finish(throwing: VotingError(
                                kind: .busy,
                                retryable: true,
                                message: "another driver holds this round"
                            ))
                            return
                        }
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2)
            }

            #expect(recorder.events().filter { $0 == "runRound" }.count == 2)
            #expect(sleeps.value == [Swift.Duration.seconds(VotingCoordFlow.runFailureRetrySeconds)])

            // The same call, refused rather than busy: nothing is scheduled and the
            // voter is told.
            let refusedRecorder = EventRecorder()
            let refusedSleeps = LockIsolated<[Swift.Duration]>([])
            let refusedStore = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: refusedRecorder)
                $0.continuousClock = RecordingImmediateClock(sleeps: refusedSleeps)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = refusedRecorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.setBallotIntents = { _, _ in try self.plan(allDecided: true) }
                $0.votingCrypto.runRound = { _, _, _ in
                    refusedRecorder.record("runRound")
                    return AsyncThrowingStream { continuation in
                        continuation.finish(throwing: VotingError(
                            kind: .invalidInput,
                            retryable: false,
                            message: "the ballot names a proposal outside the roster"
                        ))
                    }
                }
            }

            refusedStore.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(refusedStore.state) }

            refusedStore.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                refusedStore.state.roundCache[self.activeRoundId]?.batchSubmissionStatus.isFailureState == true
            }

            #expect(refusedRecorder.events().filter { $0 == "runRound" } == ["runRound"])
            #expect(refusedSleeps.value.isEmpty)
            guard
                case let .authorizationFailed(error) =
                    tryUnwrap(refusedStore.state.roundCache[activeRoundId]).batchSubmissionStatus
            else {
                Issue.record("a refused run must fail the authorization rather than retry")
                return
            }
            #expect(!error.isEmpty)
            #expect(refusedStore.state.roundCache[activeRoundId]?.runRetryCount == 0)
        }

        /// The contention this ladder exists for does not arrive as a crate error
        /// at all. Run/track exclusivity is enforced by the SDK wrapper, which
        /// throws its own `VotingRustBackendError.sessionBusy` — a different type,
        /// with no `retryable` of its own — so a flow that only understood
        /// `VotingError` would flatten the one refusal the ladder was built for
        /// into a hard failure. The real type is driven again and lands.
        @MainActor
        @Test func aBusySessionFromTheSdkTakesTheSameBoundedLadder() async throws {
            let recorder = EventRecorder()
            let sleeps = LockIsolated<[Swift.Duration]>([])
            let report = try runReport(
                kind: "no_work_left",
                completedProposals: 2,
                totalProposals: 2,
                completedChoices: [(1, 0), (2, 1)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.continuousClock = RecordingImmediateClock(sleeps: sleeps)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.setBallotIntents = { _, _ in try self.plan(allDecided: true) }
                $0.votingCrypto.runRound = { _, _, _ in
                    let call = recorder.recordAndCount("runRound")
                    return AsyncThrowingStream { continuation in
                        guard call > 1 else {
                            // What a share-tracking pass holding this round's
                            // session actually throws.
                            continuation.finish(throwing: VotingRustBackendError.sessionBusy)
                            return
                        }
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2)
            }

            #expect(recorder.events().filter { $0 == "runRound" }.count == 2)
            #expect(sleeps.value == [Swift.Duration.seconds(VotingCoordFlow.runFailureRetrySeconds)])
        }

        /// The other half of the same mapping. A closed session is finished rather
        /// than paused, so repeating the call answers the same way however long the
        /// flow waits: nothing is scheduled and the voter is told.
        @MainActor
        @Test func aClosedSessionFromTheSdkIsNotRetried() async throws {
            let recorder = EventRecorder()
            let sleeps = LockIsolated<[Swift.Duration]>([])
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.continuousClock = RecordingImmediateClock(sleeps: sleeps)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.setBallotIntents = { _, _ in try self.plan(allDecided: true) }
                $0.votingCrypto.runRound = { _, _, _ in
                    recorder.record("runRound")
                    return AsyncThrowingStream { continuation in
                        continuation.finish(throwing: VotingRustBackendError.sessionClosed)
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus.isFailureState == true
            }

            #expect(recorder.events().filter { $0 == "runRound" } == ["runRound"])
            #expect(sleeps.value.isEmpty)
            #expect(store.state.roundCache[activeRoundId]?.runRetryCount == 0)
        }

        // MARK: - P6 A run that completes after an account switch writes nothing

        /// The fence is on the writes, not only on the screen: a run whose report
        /// lands after the wallet changed has produced a completed ballot for an
        /// account this flow no longer holds, so nothing of it reaches the
        /// account-scoped metadata and no completion is published.
        @MainActor
        @Test func aRunCompletingAfterAnAccountSwitchWritesNoMetadata() async throws {
            let recorder = EventRecorder()
            let metadata = VotingMetadataBox()
            let gate = TestGate()
            let report = try runReport(
                kind: "no_work_left",
                completedProposals: 2,
                totalProposals: 2,
                completedChoices: [(1, 0), (2, 1)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingMetadata = self.recordingVotingMetadata(metadata, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.setBallotIntents = { _, _ in try self.plan(allDecided: true) }
                $0.votingCrypto.setOperationEpoch = { _, _ in }
                $0.votingCrypto.closeRoundSession = { roundId in recorder.record("closeRoundSession:\(roundId)") }
                $0.votingCrypto.runRound = { _, _, _ in
                    recorder.record("runRound")
                    return AsyncThrowingStream { continuation in
                        let task = Task {
                            await gate.wait()
                            continuation.yield(VotingRoundRunEvent.finished(report))
                            continuation.finish()
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    }
                }
                $0.votingAPI.fetchServiceConfig = { _ in throw VotingError(kind: .other, message: "no config in this test") }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }
            let openedEpoch = try #require(store.state.roundCache[activeRoundId]?.sessionEpoch)

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { recorder.events().contains("runRound") }

            store.send(.walletAccountChanged(keystoneWalletAccount()))
            await waitForStore { recorder.events().contains("closeRoundSession:\(self.activeRoundId)") }
            recorder.record("accountSwitched")

            await gate.open()
            await store.send(.roundRunEvent(roundId: activeRoundId, epoch: openedEpoch, event: .finished(report))).finish()

            let afterTheSwitch = recorder.events().drop { $0 != "accountSwitched" }
            #expect(
                !afterTheSwitch.contains { $0.hasPrefix("setRecord") || $0.hasPrefix("setSubmittedVotes") },
                "a run that finished for the previous wallet must write nothing"
            )
            #expect(metadata.records.isEmpty)
            #expect(metadata.submittedVotes.isEmpty)
            #expect(store.state.voteRecords.isEmpty)
            #expect(store.state.roundCache[activeRoundId] == nil, "no completion is published for a round that is gone")
        }

        // MARK: - P7 The Keystone loop signs one bundle at a time

        /// The device signs per bundle and the crate is asked for one redacted PCZT
        /// at a time, in the order the run named: request, scan, store, next bundle,
        /// and only when every bundle the run asked for is stored is the round run
        /// again — on the signatures the crate now holds, not on anything carried
        /// across from the first run.
        @MainActor
        @Test func theKeystoneLoopSignsOneBundleAtATimeThenRerunsOnStoredSignatures() async throws {
            let recorder = EventRecorder()
            let signingReport = try runReport(
                kind: "needs_delegation_signatures",
                completedProposals: 0,
                totalProposals: 2,
                bundles: [0, 1]
            )
            let completedReport = try runReport(
                kind: "no_work_left",
                completedProposals: 2,
                totalProposals: 2,
                completedChoices: [(1, 0), (2, 1)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)], isKeystone: true)) {
                VotingCoordFlow()
            } withDependencies: {
                self.keystoneDependencies(&$0, recorder: recorder, bundleCount: 2)
                $0.votingCrypto.storeKeystoneSignatures = { _, signed in
                    recorder.record("storeKeystoneSignatures:\(Self.indexList(signed.map(\.bundleIndex)))")
                    return try self.keystoneBatchResult(inserted: UInt32(signed.count))
                }
                $0.votingCrypto.precomputeDelegationProof = { _, bundleIndex in
                    recorder.record("precompute:\(bundleIndex)")
                    return AsyncThrowingStream { $0.finish() }
                }
                $0.votingCrypto.runRound = { _, signer, _ in
                    let call = recorder.recordAndCount(Self.runRoundEvent(signer))
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(call == 1 ? signingReport : completedReport))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await scanKeystoneSignature(store, bundleIndex: 0)
            await scanKeystoneSignature(store, bundleIndex: 1)
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2)
            }

            #expect(
                recorder.events().filter { Self.isKeystoneLoopEvent($0) } == [
                    "runRound.keystoneStored",
                    "keystoneSigningRequests:0",
                    "storeKeystoneSignatures:0",
                    "keystoneSigningRequests:1",
                    "storeKeystoneSignatures:1",
                    "runRound.keystoneStored"
                ]
            )
            // Nothing warms a proof for a device that holds the key: the signature
            // is the device's, and there is no host-side proof to start early.
            #expect(!recorder.events().contains { $0.hasPrefix("precompute:") })
            #expect(store.state.roundCache[activeRoundId]?.keystoneSignedBundles == Set([0, 1]))
        }

        // MARK: - Parity fixtures

        /// The metadata client, with every write it makes named in the recorder.
        private func recordingVotingMetadata(
            _ box: VotingMetadataBox,
            recorder: EventRecorder
        ) -> VotingMetadataProviderClient {
            var client = votingMetadataClient(box)
            client.setDrafts = { drafts, roundId in
                recorder.record("setDrafts:\(roundId)")
                box.drafts[roundId] = drafts
            }
            client.setSubmittedVotes = { votes, roundId in
                recorder.record("setSubmittedVotes:\(roundId)")
                box.submittedVotes[roundId] = votes
            }
            client.setRecord = { record, roundId in
                recorder.record("setRecord:\(roundId)")
                box.records[roundId] = record
            }
            return client
        }

        private static func isKeystoneLoopEvent(_ event: String) -> Bool {
            event.hasPrefix("runRound")
                || event.hasPrefix("keystoneSigningRequests")
                || event.hasPrefix("storeKeystoneSignatures")
        }
    }
}
#endif
