#if VOTING_ENABLED
import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

extension VotingSharedStateSuites {
    // Drives a TCA coordinator that touches process-global `@Shared` state (e.g.
    // `selectedWalletAccount`) and uses plain `Store`s for the async cases, so the suite is
    // serialized to match XCTest's previous serial execution — and nested under a serialized
    // parent so the parity suite, which writes the same shared values, cannot interleave with it.
    @Suite(.serialized) struct VotingCoordFlowCoordinatorTests: VotingTestSuite {
        @Test func batchSubmissionCompletedAcceptsPartialBallotWhenDraftsAreDrained() {
            let metadata = VotingMetadataBox()
            var state = VotingCoordFlow.State()
            state.roundCache[roundId] = roundSession(
                votingWeight: 50_000_000,
                votes: [
                    1: .option(0),
                    3: .option(1)
                ]
            )

            withDependencies {
                $0.votingMetadata = votingMetadataClient(metadata)
            } operation: {
                _ = VotingCoordFlow().reduceBatchSubmissionCompleted(
                    &state,
                    roundId: roundId,
                    successCount: 2,
                    failCount: 0
                )
            }

            let session = tryUnwrap(state.roundCache[roundId])
            #expect(session.batchSubmissionStatus == .completed(successCount: 2))
            #expect(session.voteRecord?.votingWeight == 50_000_000)
            #expect(session.voteRecord?.proposalCount == 2)
            #expect(state.voteRecords[roundId]?.proposalCount == 2)
            #expect(metadata.records[roundId]?.proposalCount == 2)
        }

        @Test func batchSubmissionCompletedFailsWhenDraftsRemain() {
            var state = VotingCoordFlow.State()
            state.roundCache[roundId] = roundSession(
                drafts: [2: .option(1)],
                votes: [1: .option(0)]
            )

            _ = VotingCoordFlow().reduceBatchSubmissionCompleted(
                &state,
                roundId: roundId,
                successCount: 1,
                failCount: 0
            )

            let session = tryUnwrap(state.roundCache[roundId])
            #expect(
                session.batchSubmissionStatus == .submissionFailed(
                    error: String(localizable: .coinVoteSubmissionGenericBatchFailure),
                    submittedCount: 1,
                    totalCount: 2
                )
            )
            #expect(session.voteRecord == nil)
        }

        @Test func batchSubmissionCompletedFailsWhenVoteErrorsExist() {
            var session = roundSession(votes: [1: .option(0)])
            session.batchVoteErrors = [2: "server unavailable"]
            var state = VotingCoordFlow.State()
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().reduceBatchSubmissionCompleted(
                &state,
                roundId: roundId,
                successCount: 1,
                failCount: 0
            )

            let updated = tryUnwrap(state.roundCache[roundId])
            #expect(
                updated.batchSubmissionStatus == .submissionFailed(
                    error: "server unavailable",
                    submittedCount: 1,
                    totalCount: 1
                )
            )
            #expect(updated.voteRecord == nil)
        }

        @Test func intermediateKeystoneSignatureAdvancesToNextBundle() {
            var session = roundSession()
            session.bundleCount = 2
            session.keystoneBundlesToSign = [0, 1]
            session.currentKeystoneBundleIndex = 0
            session.keystoneSigningStatus = .parsingSignature
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().reduceKeystoneBundleSignatureStored(&state, roundId: roundId, bundleIndex: 0)

            let updated = tryUnwrap(state.roundCache[roundId])
            #expect(updated.keystoneSignedBundles == Set([0]))
            #expect(updated.nextKeystoneBundleToSign == 1)
            #expect(updated.keystoneSigningStatus == .idle)
            #expect(updated.pendingKeystoneRequest == nil)
            #expect(isDelegationSigningTop(state))
        }

        @Test func finalKeystoneSignatureMovesToFinalizingAuthorization() {
            var session = roundSession()
            session.bundleCount = 2
            session.keystoneBundlesToSign = [0, 1]
            session.keystoneSignedBundles = [0]
            session.currentKeystoneBundleIndex = 1
            session.keystoneSigningStatus = .parsingSignature
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().reduceKeystoneBundleSignatureStored(&state, roundId: roundId, bundleIndex: 1)

            let updated = tryUnwrap(state.roundCache[roundId])
            #expect(updated.keystoneSignedBundles == Set([0, 1]))
            #expect(updated.nextKeystoneBundleToSign == nil)
            #expect(updated.keystoneSigningStatus == .finalizingAuthorization)
            #expect(updated.pendingKeystoneRequest == nil)
            #expect(!isDelegationSigningTop(state))
        }

        /// The kept bundles are worth what the crate said they were worth on their
        /// own signing requests — the only figures this side has for them.
        @Test func skippingRemainingKeystoneBundlesKeepsOnlySignedWeight() {
            var session = roundSession(votingWeight: 100_000_000)
            session.eligibleVotingWeight = 100_000_000
            session.bundleCount = 2
            session.keystoneSignedBundles = [0]
            session.keystoneBundleWeights = [0: 87_500_000, 1: 12_500_000]
            session.keystoneBundlesToSign = [1]
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().reduceSkipRemainingKeystoneBundles(&state, roundId: roundId)

            let updated = tryUnwrap(state.roundCache[roundId])
            #expect(updated.bundleCount == 1)
            #expect(updated.votingWeight == 87_500_000)
            #expect(updated.eligibleBundleCount == 2)
            #expect(updated.eligibleVotingWeight == 100_000_000)
            #expect(updated.keystoneBundlesToSign.isEmpty)
            #expect(updated.keystoneSigningStatus == .finalizingAuthorization)
            #expect(!isDelegationSigningTop(state))
        }

        /// Signed bundles that do not start at the first one are no prefix, and the
        /// crate keeps a prefix: there is nothing "use signed bundles only" can do
        /// with them, so it does nothing rather than skipping across the gap.
        @Test func skippingRemainingKeystoneBundlesIgnoresASparseSignedSet() {
            var session = roundSession(votingWeight: 150_000_000)
            session.bundleCount = 3
            session.keystoneSignedBundles = [2]
            session.keystoneBundleWeights = [2: 50_000_000]
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().reduceSkipRemainingKeystoneBundles(&state, roundId: roundId)

            let updated = tryUnwrap(state.roundCache[roundId])
            #expect(updated.bundleCount == 3)
            #expect(updated.votingWeight == 150_000_000)
            #expect(updated.keystoneSignedBundles == Set([2]))
        }

        /// Re-entering a round resumes the loop on what the crate already holds
        /// rather than asking the device to sign those bundles again.
        @Test func restoredKeystoneSignaturesResumeAtFirstUnsignedBundle() throws {
            var session = roundSession()
            session.bundleCount = 3
            session.roundPlan = try plan(delegationBundlesNeedingSigning: [1, 2])
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().coordinatorReduce().reduce(
                into: &state,
                action: .keystoneSignaturesRestored(roundId: roundId, bundleIndices: [0, 1])
            )

            let updated = tryUnwrap(state.roundCache[roundId])
            #expect(updated.keystoneSignedBundles == Set([0, 1]))
            #expect(updated.keystoneBundlesToSign == [2])
            #expect(updated.currentKeystoneBundleIndex == 2)
        }

        /// The same read landing after a run has already named the bundles it wants
        /// signed: it is a snapshot taken when the session opened, so it adds what
        /// the crate held and leaves the run's list alone. Replacing that list —
        /// with a plan that names no signing work, as a plan refreshed mid-loop
        /// does — stranded the loop on the bundle it was showing.
        @Test func restoredKeystoneSignaturesNeverReplaceARunsWorkList() throws {
            var session = roundSession()
            session.bundleCount = 2
            session.roundPlan = try plan()
            session.keystoneBundlesToSign = [1]
            session.currentKeystoneBundleIndex = 1
            session.keystoneSigningStatus = .awaitingSignature
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().coordinatorReduce().reduce(
                into: &state,
                action: .keystoneSignaturesRestored(roundId: roundId, bundleIndices: [0])
            )

            let updated = tryUnwrap(state.roundCache[roundId])
            #expect(updated.keystoneBundlesToSign == [1])
            #expect(updated.keystoneSignedBundles == Set([0]))
            #expect(updated.currentKeystoneBundleIndex == 1)
        }

        @Test func delegationRejectedResetsKeystoneLoopButPreservesVotes() {
            var session = roundSession(
                drafts: [2: .option(1)],
                votes: [1: .option(0)]
            )
            session.bundleCount = 2
            session.keystoneBundlesToSign = [1]
            session.keystoneSignedBundles = [0]
            session.currentKeystoneBundleIndex = 1
            session.keystoneSigningStatus = .awaitingSignature
            session.batchSubmissionStatus = .authorizing
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.pendingBatchSubmission = true
            state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().coordinatorReduce().reduce(
                into: &state,
                action: .delegationRejected(roundId: roundId)
            )

            let updated = tryUnwrap(state.roundCache[roundId])
            // The stored signature survives: leaving the screen does not undo what
            // the device has already signed.
            #expect(updated.keystoneSignedBundles == Set([0]))
            #expect(updated.keystoneBundlesToSign.isEmpty)
            #expect(updated.currentKeystoneBundleIndex == 1)
            #expect(updated.pendingKeystoneRequest == nil)
            #expect(updated.keystoneSigningStatus == .idle)
            #expect(updated.batchSubmissionStatus == .idle)
            #expect(updated.draftVotes == [2: .option(1)])
            #expect(updated.votes == [1: .option(0)])
            #expect(!state.pendingBatchSubmission)
            #expect(!isDelegationSigningTop(state))
        }

        private let roundId = "round-1"

        private func roundSession(
            roundId: String? = nil,
            votingWeight: UInt64 = 0,
            drafts: [UInt32: VoteChoice] = [:],
            votes: [UInt32: VoteChoice] = [:]
        ) -> RoundSession {
            var session = RoundSession(roundId: roundId ?? self.roundId)
            session.votingWeight = votingWeight
            session.draftVotes = drafts
            session.votes = votes
            return session
        }

        private func isDelegationSigningTop(_ state: VotingCoordFlow.State) -> Bool {
            guard case .delegationSigning = state.path.last else {
                return false
            }
            return true
        }

        // MARK: - Round session flow (software wallets)

        /// Entering an active round opens exactly one session, and a plan that says
        /// the round has no bundle rows yet gets them persisted before the voter
        /// reaches the ballot.
        @MainActor
        @Test func openingARoundOpensASessionAndSetsUpBundlesWhenNeeded() async {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    // The first plan is the one the round is opened on; the second is
                    // the refresh `.bundlesSetUp` asks for once the rows exist.
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in
                    recorder.record("setupBundles")
                    return try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000)
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            #expect(recorder.events().filter { $0 == "openRoundSession" }.count == 1)
            #expect(recorder.events().filter { $0 == "setupBundles" }.count == 1)
            #expect(store.state.roundCache[self.activeRoundId]?.bundleCount == 1)
            #expect(store.state.roundCache[self.activeRoundId]?.votingWeight == 50_000_000)
        }

        /// A wallet the crate refuses to bundle for is not an error screen: it is
        /// the polls list with the insufficient-balance sheet, so the voter can pick
        /// another round.
        @MainActor
        @Test func ineligibleWalletShowsIneligibleScreen() async {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.plan(needsBundleSetup: true, openProposals: [1, 2]) }
                $0.votingCrypto.setupBundles = { _ in
                    recorder.record("setupBundles")
                    throw VotingError(kind: .noSpendableNotes, message: "wallet holds no spendable notes")
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { store.state.ineligibleSheet != nil }

            #expect(store.state.path.isEmpty)
            #expect(store.state.checkingEligibilityRoundId == nil)
            #expect(store.state.ineligibleSheet?.snapshotHeight == 123)
        }

        /// The precompute runs once for the bundle that owes delegation work, and
        /// Confirm does not run it again: the run reuses the proof the crate has
        /// already persisted, so the only proving the voter waits for is the one
        /// done while they were still reading the ballot.
        @MainActor
        @Test func precomputeRunsOncePerBundleAndConfirmReusesIt() async throws {
            let recorder = EventRecorder()
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
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(
                        needsBundleSetup: call == 1,
                        openProposals: [1, 2],
                        delegationBundlesNeedingWork: [0]
                    )
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.precomputeDelegationProof = { _, bundleIndex in
                    recorder.record("precompute:\(bundleIndex)")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingDelegationProofEvent.finished(VotingDelegationProofStatus.generated))
                        continuation.finish()
                    }
                }
                $0.votingCrypto.setBallotIntents = { _, _ in
                    try self.plan(allDecided: true, delegationBundlesNeedingWork: [0])
                }
                $0.votingCrypto.runRound = { _, signer, _ in
                    recorder.record(
                        signer == VotingDelegationSigner.software(seed: Self.walletSeed)
                            ? "runRound.software"
                            : "runRound.otherSigner"
                    )
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.precomputeStatus[0] == .generated }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2)
            }

            #expect(recorder.events().filter { $0.hasPrefix("precompute:") } == ["precompute:0"])
            #expect(recorder.events().filter { $0.hasPrefix("runRound") } == ["runRound.software"])
            #expect(store.state.roundCache[self.activeRoundId]?.votes == [1: .option(0), 2: .option(1)])
            #expect(store.state.roundCache[self.activeRoundId]?.draftVotes.isEmpty == true)
        }

        /// A ballot the voter left partly blank is still a complete ballot to the
        /// crate: the skipped proposals are recorded as decisions, not omitted, or
        /// the round would never plan a cast.
        @MainActor
        @Test func confirmWritesBallotIntentsIncludingSkips() async throws {
            let recorder = EventRecorder()
            let intents = LockIsolated<[VotingBallotIntent]>([])
            let report = try runReport(kind: "no_work_left", completedProposals: 1, totalProposals: 2)
            // Proposal 1 carries options 0 and 1, so choice 2 is the synthetic
            // Abstain the ballot UI offers rather than a real option.
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(2), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.setBallotIntents = { _, recorded in
                    intents.withValue { $0 = recorded }
                    return try self.plan(allDecided: true)
                }
                $0.votingCrypto.runRound = { _, _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { intents.value.count == 2 }

            #expect(
                intents.value.sorted { $0.proposalId < $1.proposalId } == [
                    VotingBallotIntent(proposalId: 1, decision: VotingBallotDecision.skipped),
                    VotingBallotIntent(proposalId: 2, decision: VotingBallotDecision.choice(1))
                ]
            )
        }

        /// A submission the chain refused is terminal: the voter is told what the
        /// chain said, with the ballot counts, and not offered a silent success.
        @MainActor
        @Test func runReportChainTerminalShowsFailure() async throws {
            let recorder = EventRecorder()
            let report = try runReport(
                kind: "chain_terminal",
                completedProposals: 0,
                totalProposals: 2,
                chainOutcomeKind: "rejected",
                diagnostic: "consensus rejected the transaction"
            )
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
                    AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus.isFailureState == true }

            guard
                case let .submissionFailed(error, submittedCount, totalCount) =
                    tryUnwrap(store.state.roundCache[activeRoundId]).batchSubmissionStatus
            else {
                Issue.record("expected a submission failure")
                return
            }
            #expect(error.contains("rejected"))
            #expect(submittedCount == 0)
            #expect(totalCount == 2)
        }

        /// A session that has been replaced has a new epoch, and the events still
        /// arriving from the old one describe a round state that no longer exists —
        /// so they are dropped rather than written back over newer state.
        @Test func staleEpochEventsAreIgnored() throws {
            var session = RoundSession(roundId: activeRoundId)
            session.sessionEpoch = 5
            session.bundleCount = 1
            var state = VotingCoordFlow.State()
            state.roundCache[activeRoundId] = session
            let before = state.roundCache
            let report = try runReport(kind: "no_work_left", completedProposals: 2, totalProposals: 2)

            _ = VotingCoordFlow().reduceRoundRunEvent(
                &state,
                roundId: activeRoundId,
                epoch: 4,
                event: VotingRoundRunEvent.finished(report)
            )

            #expect(state.roundCache == before)
        }

        /// A run that exhausts its own pass budget is retried, but not forever: the
        /// fourth exhausted run is a failure the voter is told about instead of a
        /// loop they cannot see.
        @MainActor
        @Test func retryLaterReRunsAtMostThreeTimes() async throws {
            let recorder = EventRecorder()
            let report = try runReport(kind: "pass_budget_exhausted", completedProposals: 0, totalProposals: 2)
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
                    recorder.record("runRound")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus.isFailureState == true }

            #expect(recorder.events().filter { $0 == "runRound" }.count == 4)
            #expect(store.state.roundCache[self.activeRoundId]?.runRetryCount == 3)
        }

        /// The automatic re-run is the continuation of a Confirm the voter has
        /// already authenticated, so it must not raise a second biometric sheet. An
        /// unexplained Face ID prompt seconds after a contention the voter never
        /// saw reads as an attack rather than as the app trying again.
        @MainActor
        @Test func anAutomaticRerunDoesNotAskForLocalAuthenticationAgain() async throws {
            let recorder = EventRecorder()
            let report = try runReport(kind: "pass_budget_exhausted", completedProposals: 0, totalProposals: 2)
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.localAuthentication.authenticate = {
                    recorder.record("authenticate")
                    return true
                }
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.setBallotIntents = { _, _ in try self.plan(allDecided: true) }
                $0.votingCrypto.runRound = { _, _, _ in
                    recorder.record("runRound")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus.isFailureState == true }

            // Four runs — the voter's tap and its three automatic retries — and
            // exactly one prompt, the one the voter answered.
            #expect(recorder.events().filter { $0 == "runRound" }.count == 4)
            #expect(recorder.events().filter { $0 == "authenticate" } == ["authenticate"])
        }

        /// A proposal the voter deliberately skipped is decided, not pending: it
        /// carries no choice in the plan's completed display, so draining the
        /// ballot from the display alone would leave its draft behind and rewrite a
        /// finished round into a submission failure.
        @MainActor
        @Test func skippedDraftsAreDrainedOnCompletion() async throws {
            let recorder = EventRecorder()
            // Proposal 1 is drafted as the synthetic Abstain, so the run records it
            // as skipped and the display comes back naming only proposal 2.
            let report = try runReport(
                kind: "no_work_left",
                completedProposals: 1,
                totalProposals: 2,
                completedChoices: [(2, 1)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(2), 2: .option(1)])) {
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
                    AsyncThrowingStream { continuation in
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

            let session = tryUnwrap(store.state.roundCache[activeRoundId])
            #expect(session.draftVotes.isEmpty)
            // The skipped proposal keeps the choice the voter drafted — the
            // synthetic Abstain — because that is what the review screens read.
            #expect(session.votes == [1: .option(2), 2: .option(1)])
            #expect(session.voteRecord?.proposalCount == 2)
        }

        /// A run that ends with only helper-share delivery left has cast the whole
        /// ballot, and its report may carry no plan at all — so the drafts have to
        /// come from the intents the host wrote rather than from a display.
        @MainActor
        @Test func aRunLeavingOnlyShareWorkStillDrainsTheBallot() async throws {
            let recorder = EventRecorder()
            let report = try runReport(kind: "background_share_work_only", completedProposals: 2, totalProposals: 2)
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
                    AsyncThrowingStream { continuation in
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

            let session = tryUnwrap(store.state.roundCache[activeRoundId])
            #expect(session.roundPlan != nil)
            #expect(session.draftVotes.isEmpty)
            #expect(session.votes == [1: .option(0), 2: .option(1)])
        }

        // MARK: - Round session flow (Keystone wallets)

        /// A Keystone round is signed bundle by bundle against the crate: the run
        /// stops asking for signatures, each bundle's redacted PCZT comes from
        /// `keystoneSigningRequests`, the signed PCZT goes straight back through
        /// `storeKeystoneSignatures`, and the same round is then re-run reading the
        /// stored rows.
        @MainActor
        @Test func keystoneRoundCollectsSignaturesThenReruns() async throws {
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
                recorder.events().filter { $0.hasPrefix("keystoneSigningRequests") }
                    == ["keystoneSigningRequests:0", "keystoneSigningRequests:1"]
            )
            #expect(
                recorder.events().filter { $0.hasPrefix("storeKeystoneSignatures") }
                    == ["storeKeystoneSignatures:0", "storeKeystoneSignatures:1"]
            )
            #expect(
                recorder.events().filter { $0.hasPrefix("runRound") }
                    == ["runRound.keystoneStored", "runRound.keystoneStored"]
            )
            #expect(store.state.roundCache[activeRoundId]?.votes == [1: .option(0), 2: .option(1)])
        }

        /// A signature the crate refuses — the device signed something other than
        /// the bundle on screen — stops the loop on the rejection sheet the flow
        /// already has, carrying the crate's own reason, and stores nothing.
        @MainActor
        @Test func keystoneConflictShowsRejectionSheet() async throws {
            let recorder = EventRecorder()
            let signingReport = try runReport(
                kind: "needs_delegation_signatures",
                completedProposals: 0,
                totalProposals: 2,
                bundles: [0, 1]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)], isKeystone: true)) {
                VotingCoordFlow()
            } withDependencies: {
                self.keystoneDependencies(&$0, recorder: recorder, bundleCount: 2)
                $0.votingCrypto.storeKeystoneSignatures = { _, _ in
                    recorder.record("storeKeystoneSignatures")
                    throw VotingError(kind: .keystoneSignatureConflict, message: Self.keystoneConflictMessage)
                }
                $0.votingCrypto.runRound = { _, signer, _ in
                    recorder.record(Self.runRoundEvent(signer))
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(signingReport))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await scanKeystoneSignature(store, bundleIndex: 0)
            await waitForStore { store.state.keystoneSignatureRejectionSheet != nil }

            #expect(store.state.keystoneSignatureRejectionSheet?.message == Self.keystoneConflictMessage)
            // Nothing was stored, so the bundle on screen is still the one the
            // device owes: the loop neither advances nor re-runs the round.
            #expect(store.state.roundCache[activeRoundId]?.keystoneSignedBundles.isEmpty == true)
            #expect(store.state.roundCache[activeRoundId]?.pendingKeystoneRequest?.bundleIndex == 0)
            #expect(recorder.events().filter { $0.hasPrefix("keystoneSigningRequests") } == ["keystoneSigningRequests:0"])
            #expect(recorder.events().filter { $0.hasPrefix("runRound") }.count == 1)
        }

        /// Giving up on the unsigned tail keeps only the bundles the device signed:
        /// the crate deletes the rest, and the round is re-run on what is left.
        @MainActor
        @Test func keystoneSkipRemainingDeletesBundlesAndReruns() async throws {
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
                $0.votingCrypto.deleteSkippedBundles = { _, keepCount in
                    recorder.record("deleteSkippedBundles:\(keepCount)")
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
            // The voter gives up on the second bundle once its QR is the one up.
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.pendingKeystoneRequest?.bundleIndex == 1
            }
            store.send(.skipRemainingKeystoneBundlesConfirmed(roundId: activeRoundId))
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2)
            }

            #expect(recorder.events().contains("deleteSkippedBundles:1"))
            #expect(recorder.events().filter { $0.hasPrefix("storeKeystoneSignatures") } == ["storeKeystoneSignatures:0"])
            #expect(
                recorder.events().filter { $0.hasPrefix("runRound") }
                    == ["runRound.keystoneStored", "runRound.keystoneStored"]
            )
            #expect(store.state.roundCache[activeRoundId]?.bundleCount == 1)
        }

        // MARK: - Lifecycle fencing

        /// Switching wallet accounts fences every open session before the flow
        /// forgets the round: the epoch moves first, then the run is cancelled,
        /// then the session is closed. An event from the session the switch
        /// replaced describes a wallet the flow has left, so it writes nothing.
        @MainActor
        @Test func accountSwitchCancelsAndClosesSessionsAndIgnoresLateEvents() async throws {
            let recorder = EventRecorder()
            let metadata = VotingMetadataBox()
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
                $0.votingCrypto.sessionPlan = { _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.setOperationEpoch = { roundId, epoch in
                    recorder.record("setOperationEpoch:\(roundId):\(epoch)")
                }
                $0.votingCrypto.cancelRoundSession = { roundId in recorder.record("cancelRoundSession:\(roundId)") }
                $0.votingCrypto.closeRoundSession = { roundId in recorder.record("closeRoundSession:\(roundId)") }
                // The switch re-initializes for the account it lands on. This test is
                // about the sessions it leaves behind, so that fetch is refused rather
                // than stubbed into a second round load.
                $0.votingAPI.fetchServiceConfig = { _ in throw TestError.votingDatabaseReadFailed }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }
            let openedEpoch = try #require(store.state.roundCache[activeRoundId]?.sessionEpoch)

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

            // The run that was driving the round when the account changed still has
            // its stream open, and what it reports belongs to the previous wallet.
            // Awaited to completion, so the decision and the metadata write this event
            // would have handed on have run by the time it is judged.
            await store.send(.roundRunEvent(roundId: activeRoundId, epoch: openedEpoch, event: .finished(report))).finish()

            #expect(store.state.roundCache[activeRoundId] == nil, "a late event must not resurrect the round")
            #expect(store.state.voteRecords.isEmpty)
            #expect(metadata.records.isEmpty)
        }

        /// A voter who chose Tor is never announced over a plain connection: an
        /// open the Tor route cannot serve fails the entry with Tor's own message,
        /// and nothing reopens the round on `.direct`.
        @MainActor
        @Test func torRouteUnavailableDoesNotFallBackToDirect() async {
            let recorder = EventRecorder()
            var initialState = sessionFlowState()
            initialState.$swapAPIAccess.withLock { $0 = .protected }
            let store = Store(initialState: initialState) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.openRoundSession = { _, _, route, _ in
                    recorder.record("openRoundSession:\(route)")
                    guard route == VotingTransportRoute.tor else { return }
                    throw ZcashError.torClientUnavailable
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore {
                store.state.rootScreen == .error(String(localizable: .migrationFailureTorFirstRunBody))
            }

            #expect(recorder.events().filter { $0.hasPrefix("openRoundSession") } == ["openRoundSession:tor"])
            #expect(store.state.path.isEmpty)
            #expect(store.state.roundCache[activeRoundId]?.roundPlan == nil)
        }

        /// A session's transport is fixed when it is opened, so a wallet that turns Tor
        /// on mid-round has to lose the sessions it has: they are fenced and closed, and
        /// the next entry into the round opens on the route the wallet asks for now. The
        /// wallet re-announcing the route it already had is not that, and does nothing.
        @MainActor
        @Test func routeChangeClosesOpenSessionsAndReopensOnTheNewRoute() async throws {
            let recorder = EventRecorder()
            var initialState = sessionFlowState()
            let swapAPIAccess = initialState.$swapAPIAccess
            let store = Store(initialState: initialState) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.openRoundSession = { _, _, route, epoch in
                    recorder.record("openRoundSession:\(route):\(epoch)")
                }
                $0.votingCrypto.setOperationEpoch = { roundId, epoch in
                    recorder.record("setOperationEpoch:\(roundId):\(epoch)")
                }
                $0.votingCrypto.cancelRoundSession = { roundId in recorder.record("cancelRoundSession:\(roundId)") }
                $0.votingCrypto.closeRoundSession = { roundId in recorder.record("closeRoundSession:\(roundId)") }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }
            #expect(store.state.roundCache[activeRoundId]?.sessionEpoch == 1)

            // Announced again with the value it already had — which the shared value also
            // does to every new subscriber — and then really changed. Both reach the same
            // subscriber in this order, so the single triple below is what says the first
            // one did nothing.
            swapAPIAccess.withLock { $0 = .direct }
            swapAPIAccess.withLock { $0 = .protected }
            await waitForStore { recorder.events().contains("closeRoundSession:\(self.activeRoundId)") }

            #expect(
                recorder.events().filter { Self.isSessionLifecycleEvent($0) } == [
                    "setOperationEpoch:\(activeRoundId):2",
                    "cancelRoundSession:\(activeRoundId)",
                    "closeRoundSession:\(activeRoundId)"
                ]
            )

            // Re-entering the round is the "next use" that opens on the new route.
            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { recorder.events().contains("openRoundSession:tor:3") }

            #expect(
                recorder.events().filter { $0.hasPrefix("openRoundSession") }
                    == ["openRoundSession:direct:1", "openRoundSession:tor:3"]
            )
            #expect(store.state.roundCache[activeRoundId]?.sessionEpoch == 3)
        }

        /// A fence keeps the round's cache and takes its session away, so a warm
        /// cache is no longer proof there is anything to act on. Tapping the round
        /// again is the voter's only recovery — the flow is still open, so nothing
        /// clears the cache — and it has to open a session rather than walk past
        /// the open into a Confirm the SDK answers `notOpen`.
        @MainActor
        @Test func tappingAFencedRoundOpensASessionAgain() async throws {
            let recorder = EventRecorder()
            let initialState = sessionFlowState()
            let swapAPIAccess = initialState.$swapAPIAccess
            let store = Store(initialState: initialState) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.roundPlan = { _, _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.openRoundSession = { _, _, route, epoch in
                    recorder.record("openRoundSession:\(route):\(epoch)")
                }
                $0.votingCrypto.setOperationEpoch = { _, _ in }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }
            #expect(store.state.openRoundSessionIds == [activeRoundId])

            // With the session open the cache hit is a real one, and re-tapping
            // opens nothing — which is the whole point of the fast path.
            store.send(.roundTapped(activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }
            #expect(recorder.events().filter { $0.hasPrefix("openRoundSession") } == ["openRoundSession:direct:1"])

            // The fence. `roundCache` is deliberately kept, so the round goes on
            // carrying a bound hotkey and its bundles.
            swapAPIAccess.withLock { $0 = .protected }
            await waitForStore { store.state.openRoundSessionIds.isEmpty }
            let fenced = tryUnwrap(store.state.roundCache[activeRoundId])
            #expect(fenced.hotkeyAddress != nil)
            #expect(fenced.bundleCount > 0)

            store.send(.roundTapped(activeRoundId))
            await waitForStore { recorder.events().contains("openRoundSession:tor:3") }

            #expect(store.state.openRoundSessionIds == [activeRoundId])
        }

        /// A wallet reset deletes `voting.sqlite3` while this flow's effects may still be
        /// in flight, and nothing cancels them for it: Root composes the voting flow under
        /// a case-filtered scope, so no presentation reducer runs on that path, and
        /// cancellation would not reach a `.run` already suspended inside a call anyway. A
        /// config load parked in its fetch must therefore refuse to reopen the database the
        /// reset has just closed and deleted — and must be free to open it again after.
        @MainActor
        @Test func aWalletTeardownStopsAConfigLoadFromReopeningTheSidecar() async throws {
            let recorder = EventRecorder()
            let gate = TestGate()
            let documents = try Self.temporaryDocumentsDirectory()
            defer { try? FileManager.default.removeItem(at: documents) }
            let sidecar = documents.appendingPathComponent(VotingCoordFlow.votingSidecarFileName)
            try Data([0x01]).write(to: sidecar)

            let teardownGate = VotingTeardown()
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                self.teardownDependencies(&$0, gate: teardownGate)
                $0.databaseFiles.documentsDirectory = { documents }
                $0.votingAPI.configureURLs = { _ in
                    // The first load parks where a real one waits on the network, so the
                    // reset lands while it is in flight.
                    if recorder.recordAndCount("configureURLs") == 1 {
                        await gate.wait()
                    }
                }
                $0.votingAPI.fetchAllRounds = { [] }
                $0.votingAPI.fetchZodlEndorsedRoundIds = { [] }
                $0.votingAPI.startHealthProbeSweep = { }
                $0.votingCrypto.openDatabase = { path, _ in
                    recorder.record("openDatabase")
                    // What the real one does, and the whole problem: the file is back.
                    try? Data([0x02]).write(to: URL(fileURLWithPath: path))
                }
                $0.votingCrypto.setWalletId = { _ in }
                $0.votingCrypto.configureProving = { _ in }
                $0.votingCrypto.warmProvingCaches = { }
                $0.votingCrypto.pendingShareRounds = { [] }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            store.send(.serviceConfigLoaded(Self.makeServiceConfig()))
            await waitForStore { recorder.events().contains("configureURLs") }
            #expect(store.state.hasConfiguredProving, "the load under test must have started")

            // Root's side of a reset: the drain, then the delete, with the window that
            // refuses an open in between held for the whole of it.
            var userStoredPreferences = UserPreferencesStorageClient()
            userStoredPreferences.removeAll = { }
            await withDependencies {
                // The same gate the store's effects ask, which is what the app has: the live
                // client holds one, and everything that opens or tears down goes through it.
                self.teardownDependencies(&$0, gate: teardownGate)
                $0.databaseFiles.documentsDirectory = { documents }
            } operation: {
                await Root.clearDeviceScopedWalletState(
                    userDefaults: .noOp,
                    flexaHandler: .noOp,
                    userStoredPreferences: userStoredPreferences,
                    readTransactionsStorage: .noOp,
                    closeVotingDatabase: { recorder.record("closeVotingDatabase") }
                )
            }

            #expect(recorder.events().contains("closeVotingDatabase"))
            #expect(!FileManager.default.fileExists(atPath: sidecar.path))

            // The parked load wakes up with the wallet already gone.
            await gate.open()
            await waitForStore { !store.state.hasConfiguredProving }

            #expect(!recorder.events().contains("openDatabase"), "the reset's delete must be the last word")
            #expect(
                !FileManager.default.fileExists(atPath: sidecar.path),
                "nothing may recreate the sidecar behind the reset"
            )

            // The refusal belongs to the teardown, not to the process: the next load opens.
            store.send(.serviceConfigLoaded(Self.makeServiceConfig()))
            await waitForStore { recorder.events().contains("openDatabase") }
            #expect(FileManager.default.fileExists(atPath: sidecar.path))
        }

        /// A teardown that reaches a flow which is still alive does not wait to be refused:
        /// the flow gives back the sessions it is holding, so the reset's own close has
        /// nothing left to wait on and no event from them can write back afterwards.
        @MainActor
        @Test func votingTeardownFencesTheSessionsTheFlowStillHolds() async throws {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.setOperationEpoch = { roundId, epoch in
                    recorder.record("setOperationEpoch:\(roundId):\(epoch)")
                }
                $0.votingCrypto.cancelRoundSession = { roundId in recorder.record("cancelRoundSession:\(roundId)") }
                $0.votingCrypto.closeRoundSession = { roundId in recorder.record("closeRoundSession:\(roundId)") }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.votingTeardownBegan)
            await waitForStore { recorder.events().contains("closeRoundSession:\(self.activeRoundId)") }

            #expect(
                recorder.events().filter { Self.isSessionLifecycleEvent($0) } == [
                    "setOperationEpoch:\(activeRoundId):2",
                    "cancelRoundSession:\(activeRoundId)",
                    "closeRoundSession:\(activeRoundId)"
                ]
            )
            #expect(store.state.roundCache[activeRoundId]?.sessionEpoch == 2)
        }

        // MARK: - Keystone round fixtures

        // MARK: - Round session fixtures

        // MARK: - Share tracking

        /// A helper that is still failing is re-armed on a bounded backoff rather
        /// than abandoned: 15 s after the first pass that stopped short, 30 s after
        /// the second, and the pass that confirms every share ends the ladder and
        /// resets it.
        @MainActor
        @Test func shareTrackingReArmsWithBackoffUntilConfirmed() async throws {
            let recorder = EventRecorder()
            let sleeps = LockIsolated<[Swift.Duration]>([])
            let failing = try shareTrackingReport(kind: "failing", messages: ["helper unreachable"])
            let confirmed = try shareTrackingReport(kind: "all_confirmed")
            let passStarted = try shareTrackingEvent(kind: "pass_started", pass: 1)
            let store = Store(initialState: shareTrackingState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.continuousClock = RecordingImmediateClock(sleeps: sleeps)
                $0.votingCrypto.trackShares = { _, _ in
                    let call = recorder.recordAndCount("trackShares")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingShareTrackingRunEvent.event(passStarted))
                        continuation.yield(VotingShareTrackingRunEvent.finished(call < 3 ? failing : confirmed))
                        continuation.finish()
                    }
                }
            }

            store.send(.pollShareStatus(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.shareTrackingStatus == .confirmed }

            #expect(recorder.events().filter { $0 == "trackShares" }.count == 3)
            #expect(sleeps.value == [Swift.Duration.seconds(15), Swift.Duration.seconds(30)])
            #expect(store.state.roundCache[self.activeRoundId]?.shareTrackingAttempt == 0)
        }

        /// Foreground passes run on a budget, and spending it is what hands the
        /// round back. A live pass is never cancelled to make room for a run —
        /// cancelling one ends the session under it, permanently — so an unbudgeted
        /// pass would hold the round for about an hour and the SDK would refuse the
        /// voter's next Confirm as `sessionBusy`. The budget turns that into a
        /// `passBudgetExhausted` quiescence and this flow's own 15 s ladder.
        @MainActor
        @Test func foregroundTrackingPassesRunOnABudgetAndReArmWhenItIsSpent() async throws {
            let recorder = EventRecorder()
            let sleeps = LockIsolated<[Swift.Duration]>([])
            let budgets = LockIsolated<[UInt32?]>([])
            let exhausted = try shareTrackingReport(kind: "pass_budget_exhausted")
            let confirmed = try shareTrackingReport(kind: "all_confirmed")
            let store = Store(initialState: shareTrackingState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.continuousClock = RecordingImmediateClock(sleeps: sleeps)
                $0.votingCrypto.trackShares = { _, policy in
                    let call = recorder.recordAndCount("trackShares")
                    budgets.withValue { $0.append(policy.maxPasses) }
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingShareTrackingRunEvent.finished(call == 1 ? exhausted : confirmed))
                        continuation.finish()
                    }
                }
            }

            store.send(.pollShareStatus(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.shareTrackingStatus == .confirmed }

            #expect(budgets.value.count == 2)
            #expect(budgets.value.allSatisfy { $0 == VotingCoordFlow.shareTrackingForegroundPasses })
            #expect(sleeps.value == [Swift.Duration.seconds(15)])
        }

        /// A round whose share delivery was interrupted resumes without the voter
        /// opening it: the sidecar names the rounds that still owe helper work, and
        /// the ones this wallet's authenticated config still carries get a session
        /// and a tracking pass as the flow initializes.
        @MainActor
        @Test func initializeResumesPendingShareRounds() async throws {
            let recorder = EventRecorder()
            let pending = try pendingShareRound(walletId: Self.pendingWalletId, roundId: activeRoundId)
            let nothingToTrack = try shareTrackingReport(kind: "nothing_to_track")
            var initialState = VotingCoordFlow.State()
            initialState.walletId = Self.pendingWalletId
            initialState.$selectedWalletAccount.withLock { $0 = self.zashiWalletAccount() }
            initialState.$swapAPIAccess.withLock { $0 = .direct }

            let store = Store(initialState: initialState) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingAPI.fetchServiceConfig = { _ in
                    Self.makeServiceConfig(
                        voteServers: [VotingServiceConfig.ServiceEndpoint(url: "https://vote.example.com", label: "vote")],
                        rounds: [self.activeRoundId: Self.roundEntry()]
                    )
                }
                $0.votingAPI.configureURLs = { _ in }
                $0.votingAPI.fetchAllRounds = { [self.votingSession(proposalCount: 2, voteEndsIn: 3_600)] }
                $0.votingAPI.fetchZodlEndorsedRoundIds = { [self.activeRoundId] }
                $0.votingCrypto.openDatabase = { _, _ in }
                $0.votingCrypto.setWalletId = { _ in }
                $0.votingCrypto.configureProving = { _ in }
                $0.votingCrypto.warmProvingCaches = { }
                $0.votingCrypto.pendingShareRounds = { [pending] }
                $0.votingCrypto.trackShares = { roundId, _ in
                    recorder.record("trackShares:\(roundId)")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingShareTrackingRunEvent.finished(nothingToTrack))
                        continuation.finish()
                    }
                }
            }

            store.send(.initialize)
            await waitForStore { store.state.roundCache[self.activeRoundId]?.shareTrackingStatus == .confirmed }

            #expect(recorder.events().filter { $0 == "openRoundSession" }.count == 1)
            #expect(recorder.events().contains("trackShares:\(activeRoundId)"))
            #expect(store.state.openRoundSessionIds == [activeRoundId])
        }

        /// Another pass already holds the round. Nothing to do and nothing to
        /// re-arm: the pass that holds it is the one that will report.
        @MainActor
        @Test func alreadyDrivingIsNoOp() async throws {
            let recorder = EventRecorder()
            let sleeps = LockIsolated<[Swift.Duration]>([])
            let alreadyDriving = try shareTrackingReport(kind: "already_driving")
            let store = Store(initialState: shareTrackingState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.continuousClock = RecordingImmediateClock(sleeps: sleeps)
                $0.votingCrypto.trackShares = { _, _ in
                    recorder.record("trackShares")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingShareTrackingRunEvent.finished(alreadyDriving))
                        continuation.finish()
                    }
                }
            }

            store.send(.pollShareStatus(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.isTrackingShares == false }

            #expect(recorder.events().filter { $0 == "trackShares" } == ["trackShares"])
            #expect(store.state.roundCache[self.activeRoundId]?.shareTrackingStatus == .idle)
            #expect(store.state.roundCache[self.activeRoundId]?.shareTrackingAttempt == 0)
            #expect(sleeps.value.isEmpty)
        }

        /// Re-entering a round resets the flag that says a pass is running, because
        /// the pass belonged to the session the entry is replacing. That must not
        /// let a second `.pollShareStatus` start another pass onto the session being
        /// opened: the entry's own plan is what says whether the round still owes
        /// share work, and the pass the entry left alone is still consuming — so
        /// cancelling nothing is also the point, since cancelling a pass finishes
        /// the round's session under it.
        @MainActor
        @Test func aPollDuringARoundReEntryStartsNoSecondPass() async throws {
            let recorder = EventRecorder()
            let gate = TestGate()
            let confirmed = try shareTrackingReport(kind: "all_confirmed")
            let store = Store(initialState: shareTrackingState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.cancelRoundSession = { roundId in recorder.record("cancelRoundSession:\(roundId)") }
                $0.votingCrypto.trackShares = { _, _ in
                    recorder.record("trackShares")
                    return AsyncThrowingStream { continuation in
                        let task = Task {
                            await gate.wait()
                            continuation.yield(VotingShareTrackingRunEvent.finished(confirmed))
                            continuation.finish()
                            recorder.record("trackShares.finished")
                        }
                        continuation.onTermination = { reason in
                            if case .cancelled = reason {
                                recorder.record("cancelRoundSession:consumerWentAway")
                            }
                            task.cancel()
                        }
                    }
                }
            }

            store.send(.pollShareStatus(roundId: activeRoundId))
            await waitForStore { recorder.events().contains("trackShares") }
            #expect(store.state.roundCache[self.activeRoundId]?.isTrackingShares == true)

            // Both sends land before the entry's own open can answer, so the second
            // poll sees exactly the state the re-entry left: not tracking, and a
            // session being opened.
            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            #expect(store.state.roundCache[self.activeRoundId]?.isTrackingShares == false)

            // The reducer answers synchronously, so this is the whole question: a
            // poll that had started a pass would have put the flag back on here.
            store.send(.pollShareStatus(roundId: activeRoundId))
            #expect(
                store.state.roundCache[self.activeRoundId]?.isTrackingShares == false,
                "a poll landing while the round's session is being reopened must start no pass"
            )

            await gate.open()
            await waitForStore { recorder.events().contains("trackShares.finished") }

            #expect(recorder.events().filter { $0 == "trackShares" } == ["trackShares"])
            #expect(!recorder.events().contains { $0.hasPrefix("cancelRoundSession") })
        }

        /// A vote that closes ends the round's share tracking: the pass is cancelled,
        /// and because a cancelled effect delivers no terminal action, the flags it
        /// would have cleared are cleared here. Left alone, the round keeps a pass
        /// that no longer exists and a delivery that never finishes.
        @Test func aRoundThatStopsVotingEndsItsShareTracking() {
            for status in [SessionStatus.tallying, SessionStatus.finalized] {
                var session = RoundSession(roundId: activeRoundId)
                session.isTrackingShares = true
                session.shareTrackingStatus = .tracking(pass: 2)
                session.shareTrackingAttempt = 3
                session.voteRecord = Voting.VoteRecord(
                    votedAt: Date(),
                    votingWeight: 50_000_000,
                    proposalCount: 2
                )
                var state = VotingCoordFlow.State()
                state.roundCache[activeRoundId] = session
                state.openRoundSessionIds = [activeRoundId]
                state.allRounds = [RoundListItem(roundNumber: 1, session: votingSession(proposalCount: 2))]
                state.path.append(.proposalList(ProposalList.State(roundId: activeRoundId)))

                _ = VotingCoordFlow().coordinatorReduce().reduce(
                    into: &state,
                    action: .roundStatusUpdated(roundId: activeRoundId, status: status)
                )

                let updated = tryUnwrap(state.roundCache[activeRoundId])
                #expect(updated.isTrackingShares == false)
                #expect(updated.shareTrackingStatus == .ended)
                #expect(updated.shareTrackingAttempt == 0)
            }
        }

        /// A round whose shares were confirmed before the vote closed keeps that
        /// answer: `.ended` would say they never landed.
        @Test func aClosedVoteKeepsConfirmedSharesConfirmed() {
            var session = RoundSession(roundId: activeRoundId)
            session.isTrackingShares = true
            session.shareTrackingStatus = .confirmed
            var state = VotingCoordFlow.State()
            state.roundCache[activeRoundId] = session
            state.openRoundSessionIds = [activeRoundId]
            state.allRounds = [RoundListItem(roundNumber: 1, session: votingSession(proposalCount: 2))]
            state.path.append(.proposalList(ProposalList.State(roundId: activeRoundId)))

            _ = VotingCoordFlow().coordinatorReduce().reduce(
                into: &state,
                action: .roundStatusUpdated(roundId: activeRoundId, status: .tallying)
            )

            let updated = tryUnwrap(state.roundCache[activeRoundId])
            #expect(updated.isTrackingShares == false)
            #expect(updated.shareTrackingStatus == .confirmed)
        }

        /// The re-arm is bounded by the round's own vote end. A backoff that would
        /// wake up after the vote has closed is not scheduled at all, and the round
        /// is `.ended` rather than left waiting for a pass that never comes.
        @MainActor
        @Test func shareTrackingStopsWhenTheBackoffWouldLandPastVoteEnd() async throws {
            let recorder = EventRecorder()
            let sleeps = LockIsolated<[Swift.Duration]>([])
            let failing = try shareTrackingReport(kind: "failing", messages: ["helper unreachable"])
            // The first backoff is 15 s; this round closes inside it.
            let store = Store(initialState: shareTrackingState(voteEndsIn: 5)) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.continuousClock = RecordingImmediateClock(sleeps: sleeps)
                $0.votingCrypto.trackShares = { _, _ in
                    recorder.record("trackShares")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingShareTrackingRunEvent.finished(failing))
                        continuation.finish()
                    }
                }
            }

            store.send(.pollShareStatus(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.shareTrackingStatus == .ended }

            #expect(recorder.events().filter { $0 == "trackShares" } == ["trackShares"])
            #expect(sleeps.value.isEmpty)
        }

        // MARK: - MOB-1810 health sweep hooks

        @MainActor
        @Test func votingInitializeDoesNotStartHealthSweep() async {
            let recorder = EventRecorder()
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.configureURLs = { _ in }
                $0.votingAPI.fetchAllRounds = { [] }
                $0.votingAPI.fetchZodlEndorsedRoundIds = { [] }
                $0.votingAPI.startHealthProbeSweep = { recorder.record("sweep") }
                $0.databaseFiles = .noOp
                $0.votingCrypto.openDatabase = { _, _ in }
                $0.votingCrypto.setWalletId = { _ in }
                $0.votingCrypto.configureProving = { _ in }
                $0.votingCrypto.warmProvingCaches = { }
                $0.votingCrypto.pendingShareRounds = { [] }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            store.send(.serviceConfigLoaded(Self.makeServiceConfig()))
            await waitForStore { store.state.rootScreen == .noRounds }

            #expect(recorder.events().isEmpty)
        }

        // MARK: - Process-wide proving

        /// The proving policy is fixed before anything can start the crate's pool:
        /// warming the caches is what starts it, and the pool keeps whichever policy
        /// started it, so a policy asked for afterwards is refused.
        @MainActor
        @Test func serviceConfigFixesTheProvingPolicyBeforeWarmingTheCaches() async {
            let recorder = EventRecorder()
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.configureURLs = { _ in }
                $0.votingAPI.fetchAllRounds = {
                    recorder.record("fetchAllRounds")
                    return []
                }
                $0.votingAPI.fetchZodlEndorsedRoundIds = { [] }
                $0.votingAPI.startHealthProbeSweep = { }
                $0.databaseFiles = .noOp
                $0.votingCrypto.openDatabase = { _, _ in }
                $0.votingCrypto.setWalletId = { _ in }
                $0.votingCrypto.pendingShareRounds = { [] }
                $0.votingCrypto.configureProving = { policy in
                    let workers = policy.cpuWorkerCount.map(String.init) ?? "crate"
                    recorder.record("configureProving:\(workers):\(policy.maxActiveHeavyJobs)")
                }
                $0.votingCrypto.warmProvingCaches = { recorder.record("warmProvingCaches") }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            store.send(.serviceConfigLoaded(Self.makeServiceConfig()))
            await waitForStore { recorder.events().contains("warmProvingCaches") }

            #expect(
                recorder.events().filter { $0 != "fetchAllRounds" }
                    == ["configureProving:crate:1", "warmProvingCaches"]
            )

            // Once per process, both of them: a second config load -- a chain switch,
            // say -- must not ask the crate for a policy its running pool would refuse.
            store.send(.serviceConfigLoaded(Self.makeServiceConfig()))
            await waitForStore { recorder.events().filter { $0 == "fetchAllRounds" }.count == 2 }

            #expect(recorder.events().filter { $0.hasPrefix("configureProving") }.count == 1)
            #expect(recorder.events().filter { $0 == "warmProvingCaches" }.count == 1)
        }
    }
}

private actor RecoveryOrderRecorder {
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        recordedEvents.append(event)
    }

    func recordAndCount(_ event: String) -> Int {
        recordedEvents.append(event)
        return recordedEvents.filter { $0 == event }.count
    }

    func events() -> [String] {
        recordedEvents
    }
}

private enum TestError: LocalizedError {
    case unexpectedSpendAuthExtraction
    case proofFailed
    case shareRecordWriteFailed
    case delegationSetupMissing
    case delegationProofMissing
    case votingDatabaseReadFailed

    var errorDescription: String? {
        switch self {
        case .unexpectedSpendAuthExtraction:
            return "unexpected SpendAuth extraction"
        case .proofFailed:
            return "proof failed"
        case .shareRecordWriteFailed:
            return "simulated local share-record write failure"
        case .delegationSetupMissing:
            return "simulated missing persisted delegation setup"
        case .delegationProofMissing:
            return "simulated missing persisted delegation proof"
        case .votingDatabaseReadFailed:
            return "simulated voting database read failure"
        }
    }
}
#endif
