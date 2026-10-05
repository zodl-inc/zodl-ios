#if VOTING_ENABLED
import Foundation
import Testing
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

/// How a round's live narration folds into the snapshot the UI reads.
///
/// The stream is lossy by design, so every rule here is a fold into whatever
/// the snapshot already holds rather than a state machine with transitions to
/// defend. Events are decoded from the crate's wire shape for the same reason
/// as in `VotingRoundHostDecisionTests`.
@Suite struct VotingRoundProgressTests {
    // MARK: - The four mapped cases

    @Test func aDelegationStepProgressProvesTheNamedBundle() throws {
        var snapshot = VotingRoundProgressSnapshot()

        snapshot.apply(try Self.makeEvent("""
        {
            "kind": "step_progress",
            "progress": {
                "kind": "delegation",
                "bundle_index": 2,
                "delegation_progress": "proof_progress",
                "proof_progress": 0.25
            }
        }
        """))

        #expect(snapshot.stage == VotingRoundProgressStage.proving)
        #expect(snapshot.proofFraction == 0.25)
        #expect(snapshot.activeBundleIndex == 2)
    }

    @Test func aChainOutcomeStepProgressConfirms() throws {
        var snapshot = VotingRoundProgressSnapshot()

        snapshot.apply(try Self.makeEvent(#"{"kind": "step_progress", "progress": {"kind": "chain_outcome"}}"#))

        #expect(snapshot.stage == VotingRoundProgressStage.confirming)
    }

    @Test func aRefreshedPlanCarriesTheBallotCounts() throws {
        var snapshot = VotingRoundProgressSnapshot()

        snapshot.apply(try Self.makeEvent("""
        {
            "kind": "plan_refreshed",
            "tally": {"completed_proposals": 2, "total_proposals": 5, "remaining_obligations": 3}
        }
        """))

        #expect(snapshot.completedProposals == 2)
        #expect(snapshot.totalProposals == 5)
    }

    @Test func aDelegationProofProgressSetsItsFraction() throws {
        var snapshot = VotingRoundProgressSnapshot()

        snapshot.apply(try Self.makeDelegationProgress(#"{"bundle_index": 1, "stage": "proof_progress", "fraction": 0.5}"#))

        #expect(snapshot.stage == VotingRoundProgressStage.proving)
        #expect(snapshot.proofFraction == 0.5)
        #expect(snapshot.activeBundleIndex == 1)
    }

    // MARK: - The rest of the step-progress mapping

    @Test func aCommittedVoteIsStillProving() throws {
        var snapshot = VotingRoundProgressSnapshot()

        snapshot.apply(try Self.makeEvent(#"{"kind": "step_progress", "progress": {"kind": "vote_commit", "bundle_index": 3}}"#))

        #expect(snapshot.stage == VotingRoundProgressStage.proving)
    }

    @Test func aPersistedBatchIsSubmitting() throws {
        var snapshot = VotingRoundProgressSnapshot()

        snapshot.apply(try Self.makeEvent(
            #"{"kind": "step_progress", "progress": {"kind": "delegate_and_vote_batch_persisted"}}"#
        ))

        #expect(snapshot.stage == VotingRoundProgressStage.submitting)
    }

    @Test func preparedHelperPlansAreSubmitting() throws {
        var snapshot = VotingRoundProgressSnapshot()

        snapshot.apply(try Self.makeEvent(#"{"kind": "step_progress", "progress": {"kind": "helper_plans_prepared"}}"#))

        #expect(snapshot.stage == VotingRoundProgressStage.submitting)
    }

    @Test func aShareOutcomeIsDeliveringShares() throws {
        var snapshot = VotingRoundProgressSnapshot()

        snapshot.apply(try Self.makeEvent(#"{"kind": "step_progress", "progress": {"kind": "share_outcome"}}"#))

        #expect(snapshot.stage == VotingRoundProgressStage.deliveringShares)
    }

    @Test func aConfirmedShareIsDeliveringShares() throws {
        var snapshot = VotingRoundProgressSnapshot()

        snapshot.apply(try Self.makeEvent(
            #"{"kind": "step_progress", "progress": {"kind": "share_confirmed", "share_confirmed": true}}"#
        ))

        #expect(snapshot.stage == VotingRoundProgressStage.deliveringShares)
    }

    // MARK: - Messages and the stage the events must not disturb

    @Test func aFailedStepKeepsItsMessage() throws {
        var snapshot = VotingRoundProgressSnapshot()
        snapshot.apply(try Self.makeEvent(#"{"kind": "step_progress", "progress": {"kind": "chain_outcome"}}"#))

        snapshot.apply(try Self.makeEvent(#"{"kind": "step_failed", "failure_kind": "transport", "message": "connection reset"}"#))

        #expect(snapshot.lastMessage == "connection reset")
        #expect(snapshot.stage == VotingRoundProgressStage.confirming)
    }

    @Test func aSkippedBundleIsNamedInTheMessage() throws {
        var snapshot = VotingRoundProgressSnapshot()

        snapshot.apply(try Self.makeEvent(#"{"kind": "bundle_skipped", "bundle_index": 4}"#))

        #expect(snapshot.lastMessage == "bundle 4 skipped")
    }

    @Test func awaitingARepollLeavesTheStageAlone() throws {
        var snapshot = VotingRoundProgressSnapshot()
        snapshot.apply(try Self.makeEvent(#"{"kind": "step_progress", "progress": {"kind": "chain_outcome"}}"#))

        snapshot.apply(try Self.makeEvent(#"{"kind": "awaiting_repoll", "delay_seconds": 5.0}"#))

        #expect(snapshot.stage == VotingRoundProgressStage.confirming)
    }

    // MARK: - Event factories

    /// A vote commitment is its own proof and the crate reports no fraction for
    /// it, so the delegation's last fraction must not stay on screen claiming
    /// to describe it.
    @Test func aVoteCommitStepProgressDropsTheDelegationFraction() throws {
        var snapshot = VotingRoundProgressSnapshot()

        snapshot.apply(try Self.makeEvent("""
        {
            "kind": "step_progress",
            "progress": {
                "kind": "delegation",
                "bundle_index": 1,
                "delegation_progress": "proof_progress",
                "proof_progress": 0.5
            }
        }
        """))
        snapshot.apply(try Self.makeEvent(#"{"kind": "step_progress", "progress": {"kind": "vote_commit", "bundle_index": 1}}"#))

        #expect(snapshot.stage == VotingRoundProgressStage.proving)
        #expect(snapshot.proofFraction == nil)
        #expect(snapshot.activeBundleIndex == 1)
    }

    private static func makeEvent(_ json: String) throws -> VotingRoundDriveEvent {
        try JSONDecoder().decode(VotingRoundDriveEvent.self, from: Data(json.utf8))
    }

    private static func makeDelegationProgress(_ json: String) throws -> VotingDelegationProgress {
        try JSONDecoder().decode(VotingDelegationProgress.self, from: Data(json.utf8))
    }
}
#endif
