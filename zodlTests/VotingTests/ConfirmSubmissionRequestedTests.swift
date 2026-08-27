#if VOTING_ENABLED
import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal

// MOB-1800: `.requested` — the CTA state between the Confirm tap and the end
// of the local-auth round-trip. These tests pin the state machine around it:
// the synchronous flip on tap, the decline rollback, the re-tap / duplicate-
// action no-ops, and the resume paths that must never flash `.idle` mid-run.
//
// Serialized for the same reason as `VotingCoordFlowCoordinatorTests`: the
// coordinator's State touches process-global `@Shared` storage.
@Suite(.serialized) struct ConfirmSubmissionRequestedTests {
    // The tap's own reduction must flip the status — before the auth effect
    // resolves — so the CTA disables and spins the instant it is touched.
    // The `.requested` expectation is deterministic: the effect's follow-up
    // action needs a MainActor hop, which can't happen until this test
    // suspends, and the first suspension is the `waitForStore` below.
    @MainActor
    @Test func confirmTapFlipsStatusToRequestedBeforeAuthResolves() async {
        let store = Store(initialState: zashiDraftState()) {
            VotingCoordFlow()
        } withDependencies: {
            $0.localAuthentication.authenticate = { true }
            $0.votingMetadata = votingMetadataClient()
        }

        store.send(.submitAllDraftsTapped(roundId: activeRoundId))

        #expect(store.state.roundCache[activeRoundId]?.batchSubmissionStatus == .requested)

        await waitForStore {
            store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .authorizing
        }
        let session = tryUnwrap(store.state.roundCache[activeRoundId])
        #expect(session.voteSubmissionStep == .authorizingVote)
        #expect(session.delegationProofStatus == .generating(progress: 0))
        #expect(!store.state.pendingBatchSubmission)
    }

    @MainActor
    @Test func declinedAuthRollsRequestedBackToIdle() async {
        let store = Store(initialState: zashiDraftState()) {
            VotingCoordFlow()
        } withDependencies: {
            $0.localAuthentication.authenticate = { false }
        }

        store.send(.submitAllDraftsTapped(roundId: activeRoundId))
        #expect(store.state.roundCache[activeRoundId]?.batchSubmissionStatus == .requested)

        await waitForStore {
            store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .idle
        }
        // Declining is a choice, not an error: no failure state, no pipeline
        // bookkeeping left behind.
        let session = tryUnwrap(store.state.roundCache[activeRoundId])
        #expect(!session.batchSubmissionStatus.isFailureState)
        #expect(session.voteSubmissionStep == nil)
    }

    @MainActor
    @Test func reTapWhileRequestedSpawnsNoSecondAuthPrompt() async {
        let authCalls = CallRecorder()
        var state = zashiDraftState()
        state.roundCache[activeRoundId]?.batchSubmissionStatus = .requested
        let store = Store(initialState: state) {
            VotingCoordFlow()
        } withDependencies: {
            $0.localAuthentication.authenticate = {
                authCalls.record("authenticate")
                return true
            }
        }

        store.send(.submitAllDraftsTapped(roundId: activeRoundId))

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.state.roundCache[activeRoundId]?.batchSubmissionStatus == .requested)
        #expect(authCalls.events().isEmpty)
    }

    @Test func duplicateAuthenticationSucceededWhileSubmittingIsIgnored() {
        var session = RoundSession(roundId: activeRoundId)
        session.bundleCount = 1
        session.draftVotes = [1: .option(0)]
        session.batchSubmissionStatus = .submitting(currentIndex: 0, totalCount: 1, currentProposalId: 1)
        var state = VotingCoordFlow.State()
        state.roundCache[activeRoundId] = session
        state.allRounds = [RoundListItem(roundNumber: 1, session: votingSession())]

        _ = VotingCoordFlow().reduceAuthenticationSucceeded(&state, roundId: activeRoundId)

        // Without the resume ticket a duplicate is a pure no-op — the old
        // guard let it restart (and thereby cancel) the in-flight batch
        // effect via `cancelInFlight: true`.
        #expect(state.roundCache[activeRoundId] == session)
        #expect(!state.pendingBatchSubmission)
    }

    @Test func precomputeResumeNeverResetsStatusToIdle() {
        var state = resumeWaitState()
        let flow = VotingCoordFlow()

        _ = flow.coordinatorReduce().reduce(
            into: &state,
            action: .delegationPrecomputeCompleted(roundId: activeRoundId)
        )

        // The old handler pre-cleared the ticket and reset the status to
        // `.idle` here — one visible action-cycle before the resume re-flipped
        // it (back nav re-opened, CTA flashed).
        var updated = tryUnwrap(state.roundCache[activeRoundId])
        #expect(updated.batchSubmissionStatus == .authorizing)
        #expect(updated.delegationPrecomputeStatus == .ready)
        #expect(!updated.isDelegationPrecomputeInFlight)
        #expect(state.pendingBatchSubmission)

        _ = withDependencies {
            $0.votingMetadata = votingMetadataClient()
        } operation: {
            flow.reduceAuthenticationSucceeded(&state, roundId: activeRoundId)
        }

        updated = tryUnwrap(state.roundCache[activeRoundId])
        #expect(updated.batchSubmissionStatus == .authorizing)
        #expect(!state.pendingBatchSubmission)
    }

    @Test func precomputeFailedResumeKeepsStatusAndRunsDelegationFromCold() {
        var state = resumeWaitState()
        let flow = VotingCoordFlow()

        _ = flow.coordinatorReduce().reduce(
            into: &state,
            action: .delegationPrecomputeFailed(roundId: activeRoundId, error: "pir down")
        )

        var updated = tryUnwrap(state.roundCache[activeRoundId])
        #expect(updated.batchSubmissionStatus == .authorizing)
        #expect(
            updated.delegationPrecomputeStatus
                == .failed(VotingErrorMapper.userFriendlyMessage(from: "pir down"))
        )
        #expect(state.pendingBatchSubmission)

        _ = withDependencies {
            $0.votingMetadata = votingMetadataClient()
        } operation: {
            flow.reduceAuthenticationSucceeded(&state, roundId: activeRoundId)
        }

        updated = tryUnwrap(state.roundCache[activeRoundId])
        #expect(updated.batchSubmissionStatus == .authorizing)
        #expect(!state.pendingBatchSubmission)
    }

    // The other resume sender: `.delegationProofCompleted` no longer
    // pre-clears the ticket either — `.authenticationSucceeded` both consumes
    // it and, with delegation now ready, moves straight to `.submitting`.
    @Test func delegationProofCompletedResumeLeavesTicketForConsume() {
        var session = RoundSession(roundId: activeRoundId)
        session.bundleCount = 1
        session.draftVotes = [1: .option(0)]
        session.batchSubmissionStatus = .authorizing
        session.voteSubmissionStep = .authorizingVote
        session.delegationProofStatus = .generating(progress: 0.9)
        session.isDelegationProofInFlight = true
        var state = VotingCoordFlow.State()
        state.pendingBatchSubmission = true
        state.roundCache[activeRoundId] = session
        state.allRounds = [RoundListItem(roundNumber: 1, session: votingSession())]
        let flow = VotingCoordFlow()

        _ = flow.reduceDelegationProofCompleted(&state, roundId: activeRoundId)

        var updated = tryUnwrap(state.roundCache[activeRoundId])
        #expect(updated.delegationProofStatus == .complete)
        #expect(updated.batchSubmissionStatus == .authorizing)
        #expect(state.pendingBatchSubmission)

        _ = withDependencies {
            $0.votingMetadata = votingMetadataClient()
        } operation: {
            flow.reduceAuthenticationSucceeded(&state, roundId: activeRoundId)
        }

        updated = tryUnwrap(state.roundCache[activeRoundId])
        #expect(updated.batchSubmissionStatus == .submitting(currentIndex: 0, totalCount: 1, currentProposalId: 1))
        #expect(!state.pendingBatchSubmission)
    }

    private let activeRoundId = String(repeating: "aa", count: 32)

    /// Zashi state whose session passes `canStartSubmission`: a drafted vote,
    /// a non-zero bundle count, and the round present in `allRounds`. No
    /// `serviceConfig` on purpose — like the coordinator tests, this lets
    /// `.authenticationSucceeded` apply its status mutations and then bail
    /// before spawning the batch submission `.run` effect.
    private func zashiDraftState() -> VotingCoordFlow.State {
        var session = RoundSession(roundId: activeRoundId)
        session.bundleCount = 1
        session.draftVotes = [1: .option(0)]
        var state = VotingCoordFlow.State()
        state.roundCache[activeRoundId] = session
        state.allRounds = [RoundListItem(roundNumber: 1, session: votingSession())]
        return state
    }

    /// Exactly what the Zashi precompute-wait branch of
    /// `.authenticationSucceeded` leaves behind: submission pending on the
    /// in-flight precompute, screen already showing `.authorizing`.
    private func resumeWaitState() -> VotingCoordFlow.State {
        var state = zashiDraftState()
        state.pendingBatchSubmission = true
        state.roundCache[activeRoundId]?.batchSubmissionStatus = .authorizing
        state.roundCache[activeRoundId]?.voteSubmissionStep = .authorizingVote
        state.roundCache[activeRoundId]?.delegationProofStatus = .generating(progress: 0)
        state.roundCache[activeRoundId]?.delegationPrecomputeStatus = .inProgress
        state.roundCache[activeRoundId]?.isDelegationPrecomputeInFlight = true
        return state
    }

    private func votingSession() -> VotingSession {
        VotingSession(
            voteRoundId: Data(repeating: 0xAA, count: 32),
            snapshotHeight: 123,
            snapshotBlockhash: Data(repeating: 0x01, count: 32),
            proposalsHash: Data(repeating: 0x02, count: 32),
            voteEndTime: .now.addingTimeInterval(60),
            ceremonyStart: .now.addingTimeInterval(-60),
            eaPK: Data(repeating: 0x03, count: 32),
            vkZkp1: Data(repeating: 0x04, count: 32),
            vkZkp2: Data(repeating: 0x05, count: 32),
            vkZkp3: Data(repeating: 0x06, count: 32),
            ncRoot: Data(repeating: 0x07, count: 32),
            nullifierIMTRoot: Data(repeating: 0x08, count: 32),
            creator: "creator",
            description: "Round description",
            proposals: [
                VotingProposal(
                    id: 1,
                    title: "Proposal 1",
                    description: "Description 1",
                    options: [
                        VoteOption(index: 0, label: "Support"),
                        VoteOption(index: 1, label: "Oppose")
                    ]
                )
            ],
            status: .active,
            createdAtHeight: 123,
            title: "Round"
        )
    }

    private func votingMetadataClient() -> VotingMetadataProviderClient {
        var client = VotingMetadataProviderClient()
        client.singleShareMode = { _ in nil }
        client.setSingleShareMode = { _, _ in }
        client.clearSingleShareMode = { _ in }
        return client
    }

    @MainActor
    private func waitForStore(
        // Generous ceiling: suites run in parallel and effect delivery can lag well past
        // a "reasonable" bound under full-suite load; the condition normally lands in
        // milliseconds and a real regression still fails, just slower.
        timeoutNanoseconds: UInt64 = 15_000_000_000,
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
}

private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    func events() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}
#endif
