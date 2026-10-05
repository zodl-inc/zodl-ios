#if VOTING_ENABLED
import Foundation
import Testing
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

/// What the Confirm screen shows for each submission status, pinned without
/// rendering the view.
@Suite struct ConfirmSubmissionDisplayTests: VotingTestSuite {
    // MARK: - Bottom

    @Test func anIdleScreenOffersConfirm() {
        #expect(
            ConfirmSubmissionDisplay.bottom(status: .idle, submission: VotingSubmissionProgress())
                == ConfirmSubmissionDisplay.Bottom.confirm
        )
    }

    @Test func aRequestedScreenShowsConfirmWorking() {
        #expect(
            ConfirmSubmissionDisplay.bottom(status: .requested, submission: VotingSubmissionProgress())
                == ConfirmSubmissionDisplay.Bottom.confirmInProgress
        )
    }

    @Test func aCompletedScreenOffersDone() {
        #expect(
            ConfirmSubmissionDisplay.bottom(status: .completed(successCount: 2), submission: VotingSubmissionProgress())
                == ConfirmSubmissionDisplay.Bottom.done
        )
    }

    @Test func authorizingShowsAnEmptyBar() throws {
        let shown = try #require(card(ConfirmSubmissionDisplay.bottom(status: .authorizing, submission: VotingSubmissionProgress())))

        #expect(shown.value == 0)
        #expect(shown.title == String(localizable: .coinVoteStoreSubmissionAuthorizingVote))
    }

    @Test func aRunWithoutATotalYetStartsFromTheAuthorizationSlice() throws {
        let shown = try #require(card(ConfirmSubmissionDisplay.bottom(status: .submitting, submission: VotingSubmissionProgress())))

        #expect(isClose(shown.value, ConfirmSubmissionDisplay.authorizationWeight))
        #expect(shown.title == String(localizable: .coinVoteSubmissionContinuedProcessingTitle))
    }

    @Test func aRunThatHasMeasuredNothingYetShowsItsFirstVote() throws {
        var submission = VotingSubmissionProgress()
        submission.apply(try planRefreshedEvent(completedProposals: 0, totalProposals: 36))

        let shown = try #require(card(ConfirmSubmissionDisplay.bottom(status: .submitting, submission: submission)))

        #expect(isClose(shown.value, 0.3))
        #expect(shown.title == String(localizable: .coinVoteConfirmSubmissionProgressSubmittingVoteCount("1", "36")))
    }

    @Test func aRunShowsTheVoteAfterTheQuestionsDone() throws {
        var submission = VotingSubmissionProgress()
        submission.apply(try planRefreshedEvent(completedProposals: 0, totalProposals: 4))
        submission.apply(try voteProofEvent(proposalId: 1))

        let shown = try #require(card(ConfirmSubmissionDisplay.bottom(status: .submitting, submission: submission)))

        #expect(isClose(shown.value, 0.3 + 0.7 * 0.25))
        #expect(shown.title == String(localizable: .coinVoteConfirmSubmissionProgressSubmittingVoteCount("2", "4")))
    }

    /// Every vote is proven while the chain has confirmed none: the estimate
    /// stays one short of the total until the tally says otherwise, and the
    /// card names the last vote rather than the one before it.
    @Test func aRunWhoseLastVoteWaitsForConfirmationShowsItsTotal() throws {
        var submission = VotingSubmissionProgress()
        submission.apply(try planRefreshedEvent(completedProposals: 0, totalProposals: 4))
        for proposalId in UInt32(1)...4 {
            submission.apply(try voteProofEvent(proposalId: proposalId))
        }

        let shown = try #require(card(ConfirmSubmissionDisplay.bottom(status: .submitting, submission: submission)))

        #expect(submission.estimatedCompletedProposals == 3)
        #expect(isClose(shown.value, 1))
        #expect(shown.title == String(localizable: .coinVoteConfirmSubmissionProgressSubmittingVoteCount("4", "4")))
    }

    @Test func aConfirmedTallyFillsTheBar() throws {
        var submission = VotingSubmissionProgress()
        submission.apply(try planRefreshedEvent(completedProposals: 4, totalProposals: 4))

        let shown = try #require(card(ConfirmSubmissionDisplay.bottom(status: .submitting, submission: submission)))

        #expect(isClose(shown.value, 1))
        #expect(shown.title == String(localizable: .coinVoteConfirmSubmissionProgressSubmittingVoteCount("4", "4")))
    }

    @Test func aRerunThatIsWaitingKeepsTheBarAndSaysItIsReconnecting() throws {
        var submission = VotingSubmissionProgress()
        submission.apply(try planRefreshedEvent(completedProposals: 0, totalProposals: 4))
        submission.apply(try voteProofEvent(proposalId: 1))
        submission.isRetrying = true

        // The automatic re-run passes back through requested and authorizing;
        // the card stays up the whole way.
        for status in [BatchSubmissionStatus.requested, BatchSubmissionStatus.authorizing, BatchSubmissionStatus.submitting] {
            let shown = try #require(card(ConfirmSubmissionDisplay.bottom(status: status, submission: submission)))
            #expect(isClose(shown.value, 0.3 + 0.7 * 0.25))
            #expect(shown.title == String(localizable: .coinVoteConfirmSubmissionProgressRetrying))
        }
    }

    @Test func anAuthorizationFailureKeepsItsEmptyBar() throws {
        let shown = try #require(card(ConfirmSubmissionDisplay.bottom(
            status: .authorizationFailed(error: "boom"),
            submission: VotingSubmissionProgress()
        )))

        #expect(shown.value == 0)
        #expect(shown.title == String(localizable: .coinVoteStoreSubmissionAuthorizingVote))
    }

    /// Three votes got through and the fourth failed: the bar keeps what got
    /// through, and the card names the vote that failed.
    @Test func aSubmissionFailureShowsTheVoteThatFailed() throws {
        let shown = try #require(card(ConfirmSubmissionDisplay.bottom(
            status: .submissionFailed(error: "x", submittedCount: 3, totalCount: 10),
            submission: VotingSubmissionProgress()
        )))

        #expect(isClose(shown.value, 0.3 + 0.7 * 0.3))
        #expect(shown.title == String(localizable: .coinVoteConfirmSubmissionProgressSubmittingVoteCount("4", "10")))
    }

    @Test func aFailureAfterEveryVoteWasSubmittedShowsItsTotal() throws {
        let shown = try #require(card(ConfirmSubmissionDisplay.bottom(
            status: .submissionFailed(error: "x", submittedCount: 10, totalCount: 10),
            submission: VotingSubmissionProgress()
        )))

        #expect(isClose(shown.value, 1))
        #expect(shown.title == String(localizable: .coinVoteConfirmSubmissionProgressSubmittingVoteCount("10", "10")))
    }

    // MARK: - Header

    @Test func theIdleHeaderAsksForConfirmation() {
        let software = ConfirmSubmissionDisplay.header(status: .idle, isKeystone: false)
        let keystone = ConfirmSubmissionDisplay.header(status: .requested, isKeystone: true)

        #expect(software.title == String(localizable: .coinVoteConfirmSubmissionHeaderTitleIdle))
        #expect(software.subtitle == String(localizable: .coinVoteConfirmSubmissionHeaderSubtitleIdle))
        #expect(keystone.title == String(localizable: .coinVoteConfirmSubmissionHeaderTitleIdle))
        #expect(keystone.subtitle == String(localizable: .coinVoteConfirmSubmissionHeaderSubtitleIdleKeystone))
    }

    @Test func aRunningSubmissionSaysItIsInProgress() {
        for status in [BatchSubmissionStatus.authorizing, BatchSubmissionStatus.submitting] {
            let header = ConfirmSubmissionDisplay.header(status: status, isKeystone: false)
            #expect(header.title == String(localizable: .coinVoteConfirmSubmissionHeaderTitleSubmitting))
            #expect(header.subtitle == String(localizable: .coinVoteConfirmSubmissionHeaderSubtitleSubmitting))
        }
    }

    @Test func anAuthorizationFailureSaysSoInTheHeader() {
        let withError = ConfirmSubmissionDisplay.header(
            status: .authorizationFailed(error: "The vote server is unreachable."),
            isKeystone: false
        )
        let withoutError = ConfirmSubmissionDisplay.header(status: .authorizationFailed(error: ""), isKeystone: false)

        #expect(withError.title == String(localizable: .coinVoteConfirmSubmissionAuthorizationFailedTitle))
        #expect(withError.subtitle == "The vote server is unreachable.")
        #expect(withoutError.title == String(localizable: .coinVoteConfirmSubmissionAuthorizationFailedTitle))
        #expect(withoutError.subtitle == String(localizable: .coinVoteConfirmSubmissionAuthorizationFailedMessage))
    }

    @Test func aSubmissionFailureSaysSoInTheHeader() {
        let withError = ConfirmSubmissionDisplay.header(
            status: .submissionFailed(error: "Rejected.", submittedCount: 1, totalCount: 2),
            isKeystone: false
        )
        let withoutError = ConfirmSubmissionDisplay.header(
            status: .submissionFailed(error: "", submittedCount: 1, totalCount: 2),
            isKeystone: false
        )

        #expect(withError.title == String(localizable: .coinVoteConfirmSubmissionSubmissionFailedTitle))
        #expect(withError.subtitle == "Rejected.")
        #expect(withoutError.title == String(localizable: .coinVoteConfirmSubmissionSubmissionFailedTitle))
        #expect(withoutError.subtitle == String(localizable: .coinVoteConfirmSubmissionSubmissionFailedMessage))
    }

    @Test func aCompletedSubmissionSaysItIsDone() {
        let header = ConfirmSubmissionDisplay.header(status: .completed(successCount: 1), isKeystone: false)

        #expect(header.title == String(localizable: .coinVoteConfirmSubmissionHeaderTitleCompleted))
        #expect(header.subtitle == String(localizable: .coinVoteConfirmSubmissionHeaderSubtitleCompleted))
    }

    // MARK: - Helpers

    private func card(_ bottom: ConfirmSubmissionDisplay.Bottom) -> (value: Double, title: String)? {
        guard case let .progress(value, title) = bottom else { return nil }
        return (value, title)
    }

    private func voteProofEvent(proposalId: UInt32) throws -> VotingRoundDriveEvent {
        try driveEvent("""
        {
            "kind": "step_progress",
            "step": {"kind": "cast_vote", "bundle_index": 0, "proposal_id": \(proposalId), "choice": 0, "share_index": 0},
            "progress": {
                "kind": "vote_commit",
                "bundle_index": 0,
                "proposal_id": \(proposalId),
                "vote_commit_stage": "proof_progress",
                "proof_progress": 1.0
            }
        }
        """)
    }

    private func isClose(_ actual: Double, _ expected: Double) -> Bool {
        abs(actual - expected) < 1e-9
    }
}
#endif
