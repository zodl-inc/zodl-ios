#if VOTING_ENABLED
import Foundation
import Testing
@preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

/// How a run's narration folds into the per-run snapshot: the crate's tally,
/// which the failure states quote, and the last failure worth naming. The
/// Confirm screen's measurement is ``VotingSubmissionProgress``'s, pinned in
/// its own suites. Events are decoded from the crate's wire shape for the same
/// reason as in `VotingRoundHostDecisionTests`.
@Suite struct VotingRoundProgressTests {
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

    @Test func aFailedStepKeepsItsMessage() throws {
        var snapshot = VotingRoundProgressSnapshot()

        snapshot.apply(try Self.makeEvent(#"{"kind": "step_failed", "failure_kind": "transport", "message": "connection reset"}"#))

        #expect(snapshot.lastMessage == "connection reset")
    }

    @Test func aSkippedBundleIsNamedInTheMessage() throws {
        var snapshot = VotingRoundProgressSnapshot()

        snapshot.apply(try Self.makeEvent(#"{"kind": "bundle_skipped", "bundle_index": 4}"#))

        #expect(snapshot.lastMessage == "bundle 4 skipped")
    }

    @Test func progressFromInsideAStepLeavesTheSnapshotAlone() throws {
        var snapshot = VotingRoundProgressSnapshot()
        snapshot.apply(try Self.makeEvent("""
        {
            "kind": "plan_refreshed",
            "tally": {"completed_proposals": 2, "total_proposals": 5, "remaining_obligations": 3}
        }
        """))
        let before = snapshot

        snapshot.apply(try Self.makeEvent("""
        {
            "kind": "step_progress",
            "progress": {"kind": "vote_commit", "bundle_index": 0, "proposal_id": 1, "proof_progress": 1.0}
        }
        """))

        #expect(snapshot == before)
    }

    private static func makeEvent(_ json: String) throws -> VotingRoundDriveEvent {
        try JSONDecoder().decode(VotingRoundDriveEvent.self, from: Data(json.utf8))
    }
}
#endif
