#if VOTING_ENABLED
import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

// Drives a TCA coordinator that touches process-global `@Shared` state (e.g. `selectedWalletAccount`)
// and uses plain `Store`s for the async cases, so the suite is serialized to match XCTest's previous
// serial execution and avoid cross-test races on that shared state.
@Suite(.serialized) struct VotingCoordFlowCoordinatorTests {
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
    private let activeRoundId = String(repeating: "aa", count: 32)

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

    private func votingSession(
        status: SessionStatus = .active,
        proposalCount: Int = 1,
        voteEndsIn: TimeInterval = 60
    ) -> VotingSession {
        VotingSession(
            voteRoundId: Data(repeating: 0xAA, count: 32),
            snapshotHeight: 123,
            snapshotBlockhash: Data(repeating: 0x01, count: 32),
            proposalsHash: Data(repeating: 0x02, count: 32),
            voteEndTime: .now.addingTimeInterval(voteEndsIn),
            ceremonyStart: .now.addingTimeInterval(-60),
            eaPK: Data(repeating: 0x03, count: 32),
            vkZkp1: Data(repeating: 0x04, count: 32),
            vkZkp2: Data(repeating: 0x05, count: 32),
            vkZkp3: Data(repeating: 0x06, count: 32),
            ncRoot: Data(repeating: 0x07, count: 32),
            nullifierIMTRoot: Data(repeating: 0x08, count: 32),
            creator: "creator",
            description: "Round description",
            proposals: (1...max(proposalCount, 1)).map { index in
                VotingProposal(
                    id: UInt32(index),
                    title: "Proposal \(index)",
                    description: "Description \(index)",
                    options: [
                        VoteOption(index: 0, label: "Support"),
                        VoteOption(index: 1, label: "Oppose")
                    ]
                )
            },
            status: status,
            createdAtHeight: 123,
            title: "Round"
        )
    }

    private static func makeServiceConfig(
        voteServers: [VotingServiceConfig.ServiceEndpoint] = [],
        rounds: [String: VotingServiceConfig.RoundEntry] = [:]
    ) -> VotingServiceConfig {
        VotingServiceConfig(
            configVersion: 1,
            voteServers: voteServers,
            pirEndpoints: [VotingServiceConfig.ServiceEndpoint(url: "https://pir.example.com", label: "pir")],
            supportedVersions: VotingServiceConfig.SupportedVersions(
                pir: ["v0"],
                voteProtocol: "v0",
                tally: "v0",
                voteServer: "v1"
            ),
            rounds: rounds,
            pirLayout: VotingServiceConfig.PirLayout(pirDepth: 1, tier0Layers: 1, tier1Layers: 1, polyLen: 4096)
        )
    }

    private static func roundEntry() -> VotingServiceConfig.RoundEntry {
        VotingServiceConfig.RoundEntry(
            authVersion: 2,
            eaPk: Data(repeating: 0x03, count: 32),
            signatures: []
        )
    }

    private func isDelegationSigningTop(_ state: VotingCoordFlow.State) -> Bool {
        guard case .delegationSigning = state.path.last else {
            return false
        }
        return true
    }

    @MainActor
    private func waitForStore(
        // Generous ceiling, not a responsiveness claim: starved CI runners have inflated
        // trivially-fast tests to 60-120 s (unit_tests runs 33367909253, 33371909793 — the
        // 2 s budget this replaces lost twice), the poll exits the moment the condition
        // lands, and a real regression still fails, just slower.
        timeoutNanoseconds: UInt64 = 60_000_000_000,
        sourceLocation: SourceLocation = #_sourceLocation,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition(), "Timed out waiting for store state", sourceLocation: sourceLocation)
    }

    private func tryUnwrap<T>(_ value: T?) -> T {
        guard let value else {
            fatalError("tryUnwrap: required value was unexpectedly nil")
        }
        return value
    }

    private func keystoneWalletAccount() -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: "Keystone",
            keySource: String(localizable: .accountsKeystone).lowercased(),
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        ))
    }

    private func zashiWalletAccount() -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: 0x03, count: 16)),
            name: "Zashi",
            keySource: nil,
            seedFingerprint: [UInt8](repeating: 0x04, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        ))
    }

    private func votingMetadataClient(
        _ box: VotingMetadataBox
    ) -> VotingMetadataProviderClient {
        var client = VotingMetadataProviderClient()
        client.load = { _ in }
        client.store = { _ in }
        client.resetAccount = { _ in }
        client.reset = {}
        client.loadDrafts = { box.drafts[$0] ?? [:] }
        client.setDrafts = { drafts, roundId in box.drafts[roundId] = drafts }
        client.clearDrafts = { roundId in box.drafts[roundId] = [:] }
        client.loadSubmittedVotes = { box.submittedVotes[$0] ?? [:] }
        client.setSubmittedVotes = { votes, roundId in
            box.submittedVotes[roundId] = votes
        }
        client.clearSubmittedVotes = { roundId in box.submittedVotes[roundId] = [:] }
        client.record = { box.records[$0] }
        client.allRecords = { box.records }
        client.setRecord = { record, roundId in box.records[roundId] = record }
        client.clearRecord = { roundId in box.records.removeValue(forKey: roundId) }
        return client
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

    /// Wires one gate into the voting client, so a store's effects and a Root reset running
    /// beside them ask the same one — which is what the app does, the live client holding it.
    private func teardownDependencies(_ dependencies: inout DependencyValues, gate: VotingTeardown) {
        dependencies.votingCrypto.beginWalletTeardown = { gate.begin() }
        dependencies.votingCrypto.endWalletTeardown = { gate.end() }
        dependencies.votingCrypto.teardownGenerationIfIdle = { gate.generationIfIdle }
        dependencies.votingCrypto.teardownAllowsOpen = { gate.allowsOpen(capturedGeneration: $0) }
        dependencies.votingCrypto.teardownBegan = { gate.began }
    }

    /// A directory of this test's own to stand in for `Documents`.
    ///
    /// The sidecar has one name and the suites run in parallel, so two tests that
    /// each create and delete the real `Documents/voting.sqlite3` would be deleting
    /// each other's.
    static func temporaryDocumentsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voting-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func isSessionLifecycleEvent(_ event: String) -> Bool {
        event.hasPrefix("setOperationEpoch")
            || event.hasPrefix("cancelRoundSession")
            || event.hasPrefix("closeRoundSession")
    }

    // MARK: - Keystone round fixtures

    private static let keystoneConflictMessage = "a stored signature disagrees with the scanned bundle"

    /// Signs whichever bundle the flow has put on screen, the way the voter
    /// does it: open the scanner, then hand back the PCZT the device signed.
    @MainActor
    private func scanKeystoneSignature(_ store: StoreOf<VotingCoordFlow>, bundleIndex: UInt32) async {
        await waitForStore {
            store.state.roundCache[self.activeRoundId]?.pendingKeystoneRequest?.bundleIndex == bundleIndex
        }
        store.send(.openKeystoneSignatureScan)
        store.send(.keystoneScan(.presented(.foundVotingDelegationPCZT(Data([0xAB, UInt8(bundleIndex)])))))
    }

    /// Everything a Keystone round touches outside the per-test signature and
    /// run stubs.
    private func keystoneDependencies(
        _ dependencies: inout DependencyValues,
        recorder: EventRecorder,
        bundleCount: UInt32
    ) {
        sessionDependencies(&dependencies, recorder: recorder)
        dependencies.keystoneHandler = .noOp
        dependencies.votingCrypto.sessionPlan = { _ in
            let call = recorder.recordAndCount("sessionPlan")
            return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
        }
        dependencies.votingCrypto.setupBundles = { _ in
            try self.bundleLayout(bundleCount: bundleCount, eligibleWeight: 100_000_000)
        }
        dependencies.votingCrypto.setBallotIntents = { _, _ in try self.plan(allDecided: true) }
        dependencies.votingCrypto.keystoneSignatures = { _ in [] }
        dependencies.votingCrypto.keystoneSigningRequests = { _, bundleIndices in
            recorder.record("keystoneSigningRequests:\(Self.indexList(bundleIndices))")
            return try bundleIndices.map {
                try self.keystoneSigningRequest(bundleIndex: $0, bundleCount: bundleCount)
            }
        }
    }

    private static func runRoundEvent(_ signer: VotingDelegationSigner) -> String {
        signer == VotingDelegationSigner.keystoneStored ? "runRound.keystoneStored" : "runRound.otherSigner"
    }

    private static func indexList(_ indices: [UInt32]) -> String {
        indices.map { String($0) }.joined(separator: ",")
    }

    private func keystoneSigningRequest(
        bundleIndex: UInt32,
        bundleCount: UInt32,
        delegatedWeight: UInt64 = 50_000_000,
        eligibleWeight: UInt64 = 100_000_000
    ) throws -> VotingKeystoneSigningRequest {
        let payload: [String: Any] = [
            "bundle_index": Int(bundleIndex),
            "bundle_count": Int(bundleCount),
            "redacted_pczt": Data([0x0A, UInt8(bundleIndex)]).base64EncodedString(),
            "pczt_sighash": Data(repeating: UInt8(bundleIndex) + 1, count: 32).base64EncodedString(),
            "rk": Data(repeating: 0x0C, count: 32).base64EncodedString(),
            "action_index": 0,
            "display_memo": "Round",
            "eligible_weight_zatoshi": Int(eligibleWeight),
            "delegated_weight_zatoshi": Int(delegatedWeight)
        ]
        return try JSONDecoder().decode(
            VotingKeystoneSigningRequest.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    private func keystoneBatchResult(inserted: UInt32) throws -> VotingKeystoneSignatureBatchResult {
        let payload: [String: Any] = ["inserted": Int(inserted), "already_present": 0]
        return try JSONDecoder().decode(
            VotingKeystoneSignatureBatchResult.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    // MARK: - Round session fixtures

    private static let walletSeed = [UInt8](repeating: 0x07, count: 32)

    /// The state an active round is entered from: one active round, a resolved
    /// service config, a software wallet account, and the polls-list spinner the
    /// entry is expected to clear.
    private func sessionFlowState(
        drafts: [UInt32: VoteChoice] = [:],
        isKeystone: Bool = false,
        voteEndsIn: TimeInterval = 60
    ) -> VotingCoordFlow.State {
        var session = RoundSession(roundId: activeRoundId)
        session.draftVotes = drafts
        var state = VotingCoordFlow.State()
        state.roundCache[activeRoundId] = session
        state.allRounds = [
            RoundListItem(roundNumber: 1, session: votingSession(proposalCount: 2, voteEndsIn: voteEndsIn))
        ]
        state.serviceConfig = Self.makeServiceConfig(
            voteServers: [VotingServiceConfig.ServiceEndpoint(url: "https://vote.example.com", label: "vote")]
        )
        state.checkingEligibilityRoundId = activeRoundId
        state.isKeystoneUser = isKeystone
        state.$selectedWalletAccount.withLock { $0 = isKeystone ? keystoneWalletAccount() : zashiWalletAccount() }
        state.$swapAPIAccess.withLock { $0 = .direct }
        return state
    }

    /// Everything the round-session path touches outside `votingCrypto`'s
    /// session calls, which each test stubs for itself.
    private func sessionDependencies(_ dependencies: inout DependencyValues, recorder: EventRecorder) {
        dependencies.sdkSynchronizer = .mocked(
            latestState: {
                var latestState = SynchronizerState.zero
                latestState.fullyScannedHeight = 1_000
                return latestState
            }
        )
        dependencies.sdkSynchronizer.getTreeState = { _ in Data([0x01]) }
        dependencies.databaseFiles.dataDbURLFor = { _ in URL(fileURLWithPath: "/tmp/voting-tests-data.db") }
        dependencies.mnemonic.toSeed = { _ in Self.walletSeed }
        dependencies.walletStorage.exportWallet = { StoredWallet.placeholder }
        dependencies.walletStorage.exportVotingHotkey = { _ in
            StoredVotingHotkey(storedSecret: VotingHotkeySecret(Data(repeating: 0x11, count: 32)), version: 1)
        }
        dependencies.localAuthentication.authenticate = { true }
        dependencies.backgroundTask = .noOp
        dependencies.votingAPI.startHealthProbeSweep = { }
        dependencies.votingMetadata = votingMetadataClient(VotingMetadataBox())
        dependencies.continuousClock = ImmediateClock()
        dependencies.votingCrypto.openRoundSession = { _, _, _, _ in recorder.record("openRoundSession") }
        dependencies.votingCrypto.closeRoundSession = { _ in }
        dependencies.votingCrypto.cancelRoundSession = { _ in }
        dependencies.votingCrypto.eligibility = { _ in try self.eligibilityReport() }
    }

    private func isProposalListTop(_ state: VotingCoordFlow.State) -> Bool {
        guard case .proposalList = state.path.last else { return false }
        return true
    }

    /// The crate's own wire shape for a plan, decoded rather than constructed:
    /// the SDK's views are `Decodable` only, and going through JSON keeps these
    /// tests honest about what a session actually answers with.
    private func plan(
        needsBundleSetup: Bool = false,
        openProposals: [UInt32] = [],
        allDecided: Bool = false,
        delegationBundlesNeedingWork: [UInt32] = [],
        delegationBundlesNeedingSigning: [UInt32] = [],
        completedChoices: [(UInt32, UInt32?)]? = nil
    ) throws -> VotingRoundPlan {
        let payload = planPayload(
            needsBundleSetup: needsBundleSetup,
            openProposals: openProposals,
            allDecided: allDecided,
            delegationBundlesNeedingWork: delegationBundlesNeedingWork,
            delegationBundlesNeedingSigning: delegationBundlesNeedingSigning,
            completedChoices: completedChoices
        )
        return try JSONDecoder().decode(VotingRoundPlan.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func planPayload(
        needsBundleSetup: Bool = false,
        openProposals: [UInt32] = [],
        allDecided: Bool = false,
        delegationBundlesNeedingWork: [UInt32] = [],
        delegationBundlesNeedingSigning: [UInt32] = [],
        completedChoices: [(UInt32, UInt32?)]? = nil
    ) -> [String: Any] {
        let noIntents: [Int] = []
        var payload: [String: Any] = [
            "round_id": activeRoundId,
            "pending_recovery": false,
            "blocking_recovery": false,
            "blocking_share_work": false,
            "has_unconfirmed_shares": false,
            "hotkey_bound": true,
            "completed_for_display": completedChoices != nil,
            "needs_draft_setup": false,
            "needs_bundle_setup": needsBundleSetup,
            "needs_delegation_signing": false,
            "has_in_flight_delegation": false,
            "delegation_bundles_needing_work": delegationBundlesNeedingWork.map { Int($0) },
            "delegation_bundles_needing_signing": delegationBundlesNeedingSigning.map { Int($0) },
            "needs_vote_polling": false,
            "has_remaining_vote_or_share_work": !allDecided,
            "has_recoverable_vote_or_share_work": !allDecided,
            "primary_action": needsBundleSetup ? "delegate" : "vote",
            "delegation_statuses": [["bundle_index": 0, "phase": "prepared", "terminal": false]],
            "open_proposals": openProposals.map { Int($0) },
            "unrostered_intents": noIntents,
            "immediate_share_confirmed": false,
            "all_decided": allDecided
        ]
        if let completedChoices {
            payload["completed_vote_display"] = [
                "choices": completedChoices.map { choice -> [String: Any] in
                    ["proposal_id": Int(choice.0), "choice": choice.1.map { Int($0) } as Any]
                }
            ]
        }
        return payload
    }

    private func bundleLayout(bundleCount: UInt32, eligibleWeight: UInt64) throws -> VotingBundleLayout {
        let payload: [String: Any] = [
            "bundle_count": Int(bundleCount),
            "eligible_weight": Int(eligibleWeight),
            "dropped_count": 0,
            "privacy_trim_dropped_bundles": 0,
            "privacy_trim_dropped_notes": 0
        ]
        return try JSONDecoder().decode(VotingBundleLayout.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func eligibilityReport(eligibleWeight: UInt64 = 50_000_000) throws -> VotingEligibilityReport {
        let payload: [String: Any] = [
            "distinct_note_count": 1,
            "eligible_weight": Int(eligibleWeight),
            "is_eligible": eligibleWeight > 0,
            "privacy_trim_dropped_value_zatoshi": 0
        ]
        return try JSONDecoder().decode(VotingEligibilityReport.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func runReport(
        kind: String,
        completedProposals: UInt32,
        totalProposals: UInt32,
        chainOutcomeKind: String? = nil,
        diagnostic: String? = nil,
        completedChoices: [(UInt32, UInt32?)]? = nil,
        bundles: [UInt32] = []
    ) throws -> VotingRoundRunReport {
        var quiescence: [String: Any] = ["kind": kind]
        if !bundles.isEmpty {
            quiescence["bundles"] = bundles.map { Int($0) }
        }
        if let chainOutcomeKind {
            var outcome: [String: Any] = ["kind": chainOutcomeKind]
            if let diagnostic {
                outcome["diagnostic"] = ["message": diagnostic]
            }
            quiescence["chain_outcome"] = outcome
        }
        var payload: [String: Any] = [
            "quiescence": quiescence,
            "tally": [
                "completed_proposals": Int(completedProposals),
                "total_proposals": Int(totalProposals),
                "remaining_obligations": Int(totalProposals - completedProposals)
            ]
        ]
        if let completedChoices {
            payload["plan"] = planPayload(allDecided: true, completedChoices: completedChoices)
        }
        return try JSONDecoder().decode(VotingRoundRunReport.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    // MARK: - Share tracking

    /// The wallet id the pending-share rows are scoped to. Shares belong to the
    /// wallet that delivered them, and the sidecar answers for every wallet it
    /// holds, so a round of somebody else's is not this flow's to resume.
    private static let pendingWalletId = "0303030303030303030303030303030303030303030303030303030303030303"

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

    /// A round with an open session and nothing tracking it yet -- the state a
    /// `.pollShareStatus` trigger finds -- on a vote that ends far enough away
    /// for the whole backoff ladder to fit before it.
    private func shareTrackingState() -> VotingCoordFlow.State {
        var state = sessionFlowState(voteEndsIn: 3_600)
        state.checkingEligibilityRoundId = nil
        state.openRoundSessionIds = [activeRoundId]
        state.sessionRouteAccess = .direct
        return state
    }

    private func shareTrackingReport(
        kind: String,
        passes: UInt32 = 1,
        messages: [String] = []
    ) throws -> VotingShareTrackingRunReport {
        var quiescence: [String: Any] = ["kind": kind]
        if !messages.isEmpty {
            quiescence["messages"] = messages
        }
        let payload: [String: Any] = ["quiescence": quiescence, "passes": Int(passes)]
        return try JSONDecoder().decode(
            VotingShareTrackingRunReport.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    private func shareTrackingEvent(kind: String, pass: UInt32?) throws -> VotingShareTrackingEvent {
        var payload: [String: Any] = ["kind": kind]
        if let pass {
            payload["pass"] = Int(pass)
        }
        return try JSONDecoder().decode(
            VotingShareTrackingEvent.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    private func pendingShareRound(walletId: String, roundId: String) throws -> VotingPendingShareRound {
        let payload: [String: Any] = ["wallet_id": walletId, "round_id": roundId]
        return try JSONDecoder().decode(
            VotingPendingShareRound.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
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

private final class VotingMetadataBox: @unchecked Sendable {
    var drafts: [String: [String: UInt32]] = [:]
    var submittedVotes: [String: [String: UInt32]] = [:]
    var records: [String: PersistedVotingRecord] = [:]
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

/// A one-shot gate a stubbed dependency parks on until the test opens it, so an effect can be
/// held at a chosen suspension point without a real-time sleep.
private actor TestGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let resumable = waiting
        waiting.removeAll()
        for continuation in resumable {
            continuation.resume()
        }
    }
}

/// Records what a reducer asked to sleep for and returns at once.
///
/// A `TestClock` would answer the same question, but only if the test manages
/// to advance it *after* the effect has registered its sleep — a race a plain
/// `Store` gives no hook to win. Recording the duration instead asserts the
/// backoff ladder exactly, with no real time passing and nothing to order.
///
/// `now` is a fixed instant so `sleep(for:)`'s deadline arithmetic is exact:
/// the duration recorded here is the one that was asked for, to the attosecond.
private struct RecordingImmediateClock: Clock {
    typealias Instant = ContinuousClock.Instant
    // Spelled out because `ZcashLightClientKit` exports a `Duration` of its own,
    // and an unqualified one in this file resolves to that instead.
    typealias Duration = Swift.Duration

    let sleeps: LockIsolated<[Swift.Duration]>
    let epoch = ContinuousClock().now

    var now: Instant { epoch }
    var minimumResolution: Swift.Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        sleeps.withValue { $0.append(epoch.duration(to: deadline)) }
        await Task.yield()
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    /// Appends `event` and returns how many times it has now been recorded, letting a
    /// closure double behave differently on its first call versus later calls.
    func recordAndCount(_ event: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        recordedEvents.append(event)
        return recordedEvents.filter { $0 == event }.count
    }

    func events() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
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
