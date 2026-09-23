#if VOTING_ENABLED
import Foundation
import Testing
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

/// How a run's drive events reach the tracker. Events and plans are decoded
/// from the crate's wire shape, the way a session answers with them.
@Suite struct VotingSubmissionProgressTests: VotingTestSuite {
    // MARK: - Folding events

    @Test func aRefreshedPlanSetsTheTotalAndMeasuresNothing() throws {
        var progress = VotingSubmissionProgress()

        progress.apply(try planRefreshedEvent(completedProposals: 0, totalProposals: 36))

        #expect(progress.totalProposals == 36)
        #expect(progress.completedProposals == 0)
        #expect(progress.estimatedCompletedProposals == nil)
        #expect(progress.fraction == nil)
    }

    @Test func theTallyNeverGoesBackwards() throws {
        var progress = VotingSubmissionProgress()
        progress.apply(try planRefreshedEvent(completedProposals: 3, totalProposals: 4))

        progress.apply(try planRefreshedEvent(completedProposals: 1, totalProposals: 2))

        #expect(progress.completedProposals == 3)
        #expect(progress.totalProposals == 4)
    }

    @Test func aVoteProofIsCreditedToTheQuestionItNames() throws {
        var progress = VotingSubmissionProgress()
        progress.apply(try planRefreshedEvent(completedProposals: 0, totalProposals: 4))

        // One cast step, selected with question 1, proves the bundle's whole
        // ballot; each proof names the question it is working on.
        progress.apply(try voteProofEvent(stepProposalId: 1, bundleIndex: 0, proofProposalId: 2, proofProgress: 1.0))
        progress.apply(try voteProofEvent(stepProposalId: 1, bundleIndex: 0, proofProposalId: 3, proofProgress: 1.0))

        #expect(progress.estimatedCompletedProposals == 2)
        #expect(isClose(progress.fraction, 0.5))
    }

    @Test func aDelegationProofMovesTheBarButNotTheCount() throws {
        var progress = VotingSubmissionProgress()
        progress.apply(try planRefreshedEvent(completedProposals: 0, totalProposals: 4))

        progress.apply(try driveEvent("""
        {
            "kind": "step_progress",
            "step": {"kind": "delegate", "bundle_index": 0, "proposal_id": 0, "choice": 0, "share_index": 0},
            "progress": {
                "kind": "delegation",
                "bundle_index": 0,
                "delegation_progress": "proof_progress",
                "proof_progress": 0.5
            }
        }
        """))

        #expect(progress.estimatedCompletedProposals == nil)
        #expect(isClose(progress.fraction, 0.5 / 4 * VotingRoundProgressTracker.delegationPhaseWeight))
    }

    @Test func thePlansVoteCarryingBundlesShareAQuestionsCredit() throws {
        let proof = try voteProofEvent(stepProposalId: 1, bundleIndex: 0, proofProposalId: 1, proofProgress: 1.0)
        var withPlan = VotingSubmissionProgress()
        withPlan.apply(try planRefreshedEvent(
            completedProposals: 0,
            totalProposals: 4,
            nextSteps: [("cast_vote", 0, 1), ("cast_vote", 1, 1)]
        ))
        var withoutPlan = VotingSubmissionProgress()
        withoutPlan.apply(try planRefreshedEvent(completedProposals: 0, totalProposals: 4))

        withPlan.apply(proof)
        withoutPlan.apply(proof)

        // Bundle 1 still owes question 1, so bundle 0's proof is half of it.
        #expect(isClose(withPlan.fraction, 0.125))
        #expect(withPlan.estimatedCompletedProposals == 0)
        #expect(isClose(withoutPlan.fraction, 0.25))
        #expect(withoutPlan.estimatedCompletedProposals == 1)
    }

    @Test func anyDriveEventEndsTheRetrySignal() throws {
        var progress = VotingSubmissionProgress()
        progress.isRetrying = true

        progress.apply(try driveEvent("""
        {"kind": "step_selected", "step": {"kind": "cast_vote", "bundle_index": 0, "proposal_id": 1, "choice": 0, "share_index": 0}}
        """))

        #expect(progress.isRetrying == false)
    }

    // MARK: - Which bundles carry vote work

    @Test func onlyVoteStepsMakeABundleCarryVoteWork() throws {
        var payload = planPayload()
        payload["next_steps"] = [
            nextStepPayload(kind: "delegate", bundleIndex: 3, proposalId: 0),
            nextStepPayload(kind: "cast_vote", bundleIndex: 0, proposalId: 1),
            nextStepPayload(kind: "advance_vote", bundleIndex: 1, proposalId: 1),
            nextStepPayload(kind: "advance_vote_batch", bundleIndex: 2, proposalId: 1),
            nextStepPayload(kind: "submit_shares", bundleIndex: 4, proposalId: 1),
            nextStepPayload(kind: "confirm_share", bundleIndex: 5, proposalId: 1),
            nextStepPayload(kind: "a_future_step", bundleIndex: 6, proposalId: 1),
            nextStepPayload(kind: "cast_vote", bundleIndex: 0, proposalId: 2)
        ]
        let plan = try JSONDecoder().decode(VotingRoundPlan.self, from: JSONSerialization.data(withJSONObject: payload))

        #expect(VotingSubmissionProgress.voteCarryingBundleIndexes(in: plan) == [0, 1, 2, 4])
    }

    // MARK: - Mapping the crate's steps

    @Test(arguments: ["delegate", "advance_delegation", "advance_imported_delegation"])
    func aDelegationStepBelongsToItsBundle(kind: String) throws {
        let step = try nextStep(kind: kind, bundleIndex: 2, proposalId: 0)

        #expect(VotingRoundProgressTracker.Step(step) == VotingRoundProgressTracker.Step.delegation(bundleIndex: 2))
    }

    @Test(arguments: ["cast_vote", "advance_vote", "advance_vote_batch", "submit_shares", "confirm_share"])
    func aVoteStepBelongsToItsQuestion(kind: String) throws {
        let step = try nextStep(kind: kind, bundleIndex: 2, proposalId: 7)

        #expect(
            VotingRoundProgressTracker.Step(step)
                == VotingRoundProgressTracker.Step.proposal(bundleIndex: 2, proposalId: 7)
        )
    }

    @Test func anUnnamedStepKindKeepsItsBundle() throws {
        let step = try nextStep(kind: "a_future_step", bundleIndex: 2, proposalId: 7)

        #expect(VotingRoundProgressTracker.Step(step) == VotingRoundProgressTracker.Step.unrecognised(bundleIndex: 2))
    }

    // MARK: - Helpers

    private func voteProofEvent(
        stepProposalId: UInt32,
        bundleIndex: UInt32,
        proofProposalId: UInt32,
        proofProgress: Double
    ) throws -> VotingRoundDriveEvent {
        try driveEvent("""
        {
            "kind": "step_progress",
            "step": {
                "kind": "cast_vote",
                "bundle_index": \(bundleIndex),
                "proposal_id": \(stepProposalId),
                "choice": 0,
                "share_index": 0
            },
            "progress": {
                "kind": "vote_commit",
                "bundle_index": \(bundleIndex),
                "proposal_id": \(proofProposalId),
                "vote_commit_stage": "proof_progress",
                "proof_progress": \(proofProgress)
            }
        }
        """)
    }

    private func planRefreshedEvent(
        completedProposals: UInt32,
        totalProposals: UInt32,
        nextSteps: [(kind: String, bundleIndex: UInt32, proposalId: UInt32)]
    ) throws -> VotingRoundDriveEvent {
        var plan = planPayload()
        plan["next_steps"] = nextSteps.map {
            nextStepPayload(kind: $0.kind, bundleIndex: $0.bundleIndex, proposalId: $0.proposalId)
        }
        let event: [String: Any] = [
            "kind": "plan_refreshed",
            "plan": plan,
            "tally": [
                "completed_proposals": Int(completedProposals),
                "total_proposals": Int(totalProposals),
                "remaining_obligations": Int(totalProposals - completedProposals)
            ]
        ]
        return try JSONDecoder().decode(VotingRoundDriveEvent.self, from: JSONSerialization.data(withJSONObject: event))
    }

    private func nextStepPayload(kind: String, bundleIndex: UInt32, proposalId: UInt32) -> [String: Any] {
        [
            "kind": kind,
            "bundle_index": Int(bundleIndex),
            "proposal_id": Int(proposalId),
            "choice": 0,
            "share_index": 0
        ]
    }

    private func nextStep(kind: String, bundleIndex: UInt32, proposalId: UInt32) throws -> VotingNextStep {
        try JSONDecoder().decode(
            VotingNextStep.self,
            from: JSONSerialization.data(
                withJSONObject: nextStepPayload(kind: kind, bundleIndex: bundleIndex, proposalId: proposalId)
            )
        )
    }

    private func isClose(_ actual: Double?, _ expected: Double) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) < 1e-9
    }
}
#endif
