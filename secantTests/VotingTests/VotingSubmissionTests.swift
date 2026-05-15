import Foundation
import XCTest
@testable import secant_testnet

final class VotingSubmissionTests: XCTestCase {
    func testVotingErrorMapperMapsPirProofRootMismatchToSnapshotMismatch() {
        let message = VotingErrorMapper.userFriendlyMessage(
            from: "Internal error: PIR proof root mismatch: expected aa, got bb"
        )

        XCTAssertEqual(message, String(localizable: .coinVoteStoreUserErrorPirSnapshotMismatch))
    }

    func testVotingErrorMapperMapsPirProofVerificationFailureBeforeFetchFailure() {
        let message = VotingErrorMapper.userFriendlyMessage(
            from: "PIR parallel fetch failed: PIR proof verification failed: bad path"
        )

        XCTAssertEqual(message, String(localizable: .coinVoteStoreUserErrorPirInvalidProofData))
    }

    func testAuthenticationSucceededDoesNotPersistVoteRecordBeforeSubmission() {
        let walletId = UUID().uuidString
        let roundId = UUID().uuidString
        defer {
            Voting.clearPersistedDrafts(walletId: walletId, roundId: roundId)
            Voting.clearPersistedVoteRecord(walletId: walletId, roundId: roundId)
        }

        var state = makeState(walletId: walletId, roundId: roundId, proposalCount: 1, isKeystoneUser: true)
        state.activeSession = makeSession(proposals: state.votingRound.proposals)
        state.bundleCount = 1
        state.draftVotes = [1: .option(0)]
        state.screenStack = [.pollsList, .proposalList, .confirmSubmission]

        _ = Voting().reduceSubmission(&state, .authenticationSucceeded)

        XCTAssertNil(state.voteRecord)
        XCTAssertNil(Voting.loadVoteRecord(walletId: walletId, roundId: roundId))
        XCTAssertTrue(state.pendingBatchSubmission)
        XCTAssertEqual(state.screenStack.last, .delegationSigning)
    }

    func testBatchSubmissionCompletedPersistsVoteRecordOnlyAfterFullSuccess() {
        let walletId = UUID().uuidString
        let roundId = UUID().uuidString
        defer {
            Voting.clearPersistedDrafts(walletId: walletId, roundId: roundId)
            Voting.clearPersistedVoteRecord(walletId: walletId, roundId: roundId)
        }

        var state = makeState(walletId: walletId, roundId: roundId, proposalCount: 2)
        state.votingWeight = ballotDivisor * 5
        state.votes = [
            1: .option(0),
            2: .option(1)
        ]
        Voting.persistDrafts([1: .option(0), 2: .option(1)], walletId: walletId, roundId: roundId)

        _ = Voting().reduceSubmission(&state, .batchSubmissionCompleted(successCount: 2, failCount: 0))

        guard let record = state.voteRecord else {
            return XCTFail("Expected voteRecord to be created after full submission success")
        }

        XCTAssertEqual(record.votingWeight, ballotDivisor * 5)
        XCTAssertEqual(record.proposalCount, 2)
        XCTAssertEqual(state.voteRecords[roundId], record)
        XCTAssertEqual(Voting.loadVoteRecord(walletId: walletId, roundId: roundId), record)
        XCTAssertTrue(Voting.loadDrafts(walletId: walletId, roundId: roundId).isEmpty)

        guard case .completed(let successCount) = state.batchSubmissionStatus else {
            return XCTFail("Expected completed batch submission status")
        }
        XCTAssertEqual(successCount, 2)
    }

    func testLoadCompletedVoteRecordClearsStaleRecordWhenDraftsRemain() {
        let walletId = UUID().uuidString
        let roundId = UUID().uuidString
        defer {
            Voting.clearPersistedDrafts(walletId: walletId, roundId: roundId)
            Voting.clearPersistedVoteRecord(walletId: walletId, roundId: roundId)
        }

        let record = Voting.VoteRecord(votedAt: Date(timeIntervalSince1970: 1_700_000_000), votingWeight: ballotDivisor, proposalCount: 1)
        Voting.persistVoteRecord(record, walletId: walletId, roundId: roundId)
        Voting.persistDrafts([1: .option(0)], walletId: walletId, roundId: roundId)

        XCTAssertNil(Voting.loadCompletedVoteRecord(walletId: walletId, roundId: roundId))
        XCTAssertNil(Voting.loadVoteRecord(walletId: walletId, roundId: roundId))
    }

    func testBatchSubmissionProgressClearsPreviousSubmissionStep() {
        var state = makeState(walletId: UUID().uuidString, roundId: UUID().uuidString, proposalCount: 1)
        state.voteSubmissionStep = .sendingShares
        state.currentVoteBundleIndex = 0

        _ = Voting().reduceSubmission(
            &state,
            .batchSubmissionProgress(currentIndex: 0, totalCount: 1, proposalId: 1)
        )

        XCTAssertNil(state.voteSubmissionStep)
        XCTAssertNil(state.currentVoteBundleIndex)
    }

    func testAuthenticationSucceededStartsSoftwareDelegationAtSubmitTime() {
        var state = makeState(walletId: UUID().uuidString, roundId: UUID().uuidString, proposalCount: 1)
        state.activeSession = makeSession(proposals: state.votingRound.proposals)
        state.bundleCount = 1
        state.draftVotes = [1: .option(0)]

        _ = Voting().reduceSubmission(&state, .authenticationSucceeded)

        XCTAssertFalse(state.pendingBatchSubmission)
        XCTAssertEqual(state.batchSubmissionStatus, .authorizing)
        XCTAssertEqual(state.voteSubmissionStep, .authorizingVote)
        XCTAssertEqual(state.delegationProofStatus, .generating(progress: 0))
    }

    func testNativeAbstainIsNotSyntheticAbstain() {
        let proposal = VotingProposal(
            id: 1,
            title: "Proposal",
            description: "Description",
            options: [
                VoteOption(index: 0, label: "No"),
                VoteOption(index: 1, label: "Abstain"),
                VoteOption(index: 2, label: "Yes")
            ]
        )

        XCTAssertFalse(Voting.isSyntheticAbstain(choice: .option(0), proposal: proposal))
        XCTAssertFalse(Voting.isSyntheticAbstain(choice: .option(1), proposal: proposal))
        XCTAssertFalse(Voting.isSyntheticAbstain(choice: .option(2), proposal: proposal))
    }

    func testSyntheticAbstainIsOnlyExactFallbackIndex() {
        let proposal = VotingProposal(
            id: 1,
            title: "Proposal",
            description: "Description",
            options: [
                VoteOption(index: 0, label: "No"),
                VoteOption(index: 2, label: "Yes")
            ]
        )

        XCTAssertTrue(Voting.isSyntheticAbstain(choice: .option(3), proposal: proposal))
        XCTAssertFalse(Voting.isSyntheticAbstain(choice: .option(4), proposal: proposal))
    }

    func testOutOfRangeChoiceIsNotSyntheticWhenNativeAbstainExists() {
        let proposal = VotingProposal(
            id: 1,
            title: "Proposal",
            description: "Description",
            options: [
                VoteOption(index: 0, label: "No"),
                VoteOption(index: 1, label: "Abstain"),
                VoteOption(index: 2, label: "Yes")
            ]
        )

        XCTAssertFalse(Voting.isSyntheticAbstain(choice: .option(3), proposal: proposal))
    }

    private func makeState(
        walletId: String,
        roundId: String,
        proposalCount: Int,
        isKeystoneUser: Bool = false
    ) -> Voting.State {
        let proposals = (1...proposalCount).map { index in
            VotingProposal(
                id: UInt32(index),
                title: "Proposal \(index)",
                description: "Description \(index)",
                options: [
                    VoteOption(index: 0, label: "Support"),
                    VoteOption(index: 1, label: "Oppose")
                ]
            )
        }

        return Voting.State(
            votingRound: VotingRound(
                id: roundId,
                title: "Round",
                description: "Round description",
                snapshotHeight: 123,
                snapshotDate: .now,
                votingStart: .now.addingTimeInterval(-60),
                votingEnd: .now.addingTimeInterval(60),
                proposals: proposals
            ),
            votingWeight: ballotDivisor,
            isKeystoneUser: isKeystoneUser,
            walletId: walletId,
            roundId: roundId
        )
    }

    private func makeSession(proposals: [VotingProposal]) -> VotingSession {
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
            proposals: proposals,
            status: .active,
            createdAtHeight: 123,
            title: "Round"
        )
    }
}
