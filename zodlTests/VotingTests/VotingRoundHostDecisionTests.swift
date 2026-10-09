#if VOTING_ENABLED
import Foundation
import Testing
@preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

/// The pure mapping from one run's report to the host's next move.
///
/// Reports are built by decoding the crate's own wire shape rather than by
/// calling an initialiser: the SDK's views are `Decodable` only, and going
/// through JSON keeps these tests honest about the payload a session actually
/// answers with.
@Suite struct VotingRoundHostDecisionTests {
    // MARK: - One test per quiescence kind

    @Test func noWorkLeftCompletesTheRound() throws {
        let report = try Self.makeReport(kind: "no_work_left")

        #expect(VotingRoundHostDecision.decide(report) == VotingRoundHostDecision.completed)
    }

    @Test func needsBundleSetupRunsBundleSetupAndReruns() throws {
        let report = try Self.makeReport(kind: "needs_bundle_setup")

        #expect(VotingRoundHostDecision.decide(report) == VotingRoundHostDecision.runBundleSetupThenRerun)
    }

    @Test func needsBallotCarriesTheOpenProposalsAndUnrosteredIntents() throws {
        let report = try Self.makeReport(
            kind: "needs_ballot",
            openProposals: [7, 9],
            unrosteredIntents: [9]
        )

        #expect(
            VotingRoundHostDecision.decide(report)
                == VotingRoundHostDecision.waitForBallot(openProposals: [7, 9], unrosteredIntents: [9])
        )
    }

    @Test func needsDelegationSignaturesCarriesTheBundles() throws {
        let report = try Self.makeReport(kind: "needs_delegation_signatures", bundles: [0, 1, 2])

        #expect(VotingRoundHostDecision.decide(report) == VotingRoundHostDecision.collectSignatures(bundles: [0, 1, 2]))
    }

    @Test func backgroundShareWorkOnlyStartsShareTracking() throws {
        let report = try Self.makeReport(kind: "background_share_work_only")

        #expect(VotingRoundHostDecision.decide(report) == VotingRoundHostDecision.startShareTracking)
    }

    @Test func cancelledIsCancelled() throws {
        let report = try Self.makeReport(kind: "cancelled")

        #expect(VotingRoundHostDecision.decide(report) == VotingRoundHostDecision.cancelled)
    }

    @Test func persistedChainTerminalIsTerminal() throws {
        let report = try Self.makeReport(
            kind: "persisted_chain_terminal",
            chainOutcomeKind: "rejected",
            diagnostic: "consensus rejected the transaction"
        )

        #expect(
            VotingRoundHostDecision.decide(report)
                == VotingRoundHostDecision.chainTerminal(message: "rejected: consensus rejected the transaction")
        )
    }

    @Test func chainTerminalWithoutADiagnosticFallsBackToTheStandardText() throws {
        let report = try Self.makeReport(kind: "chain_terminal", chainOutcomeKind: "submitted_without_hash")

        #expect(
            VotingRoundHostDecision.decide(report)
                == VotingRoundHostDecision.chainTerminal(message: "submitted_without_hash: submission ended without confirmation")
        )
    }

    @Test func chainRecoveryStalledRetriesInThirtySeconds() throws {
        let report = try Self.makeReport(kind: "chain_recovery_stalled")

        #expect(VotingRoundHostDecision.decide(report) == VotingRoundHostDecision.retryLater(seconds: 30))
    }

    @Test func passBudgetExhaustedRetriesPromptly() throws {
        let report = try Self.makeReport(kind: "pass_budget_exhausted")

        #expect(VotingRoundHostDecision.decide(report) == VotingRoundHostDecision.retryLater(seconds: 2))
    }

    @Test func failuresReportTheFirstFailureMessage() throws {
        let report = try Self.makeReport(
            kind: "failures",
            failures: [
                VotingRoundHostDecisionTests.Failure(kind: "proof_failed", message: "proving ran out of memory"),
                VotingRoundHostDecisionTests.Failure(kind: "transport", message: "connection reset")
            ]
        )

        #expect(
            VotingRoundHostDecision.decide(report)
                == VotingRoundHostDecision.failed(message: "proving ran out of memory", retryable: false)
        )
    }

    @Test func anUnrecognisedQuiescenceFailsWithoutRetrying() throws {
        let report = try Self.makeReport(kind: "a_kind_this_sdk_does_not_name")

        #expect(
            VotingRoundHostDecision.decide(report)
                == VotingRoundHostDecision.failed(message: "unknown quiescence", retryable: false)
        )
    }

    // MARK: - Retryability and message detail

    @Test func aTransportFailureRerunsTheFailedBundles() throws {
        let report = try Self.makeReport(
            kind: "failures",
            failures: [VotingRoundHostDecisionTests.Failure(kind: "transport", message: "connection reset")]
        )

        #expect(
            VotingRoundHostDecision.decide(report)
                == VotingRoundHostDecision.rerunFailedBundles(message: "connection reset", seconds: 2)
        )
    }

    @Test func aBusyFailureRerunsTheFailedBundles() throws {
        let report = try Self.makeReport(
            kind: "failures",
            failures: [VotingRoundHostDecisionTests.Failure(kind: "busy", message: "the round is held")]
        )

        #expect(
            VotingRoundHostDecision.decide(report)
                == VotingRoundHostDecision.rerunFailedBundles(message: "the round is held", seconds: 2)
        )
    }

    @Test func failuresThatAreAllTransientRerunWithTheFirstMessage() throws {
        let report = try Self.makeReport(
            kind: "failures",
            failures: [
                VotingRoundHostDecisionTests.Failure(kind: "transport", message: "connection reset"),
                VotingRoundHostDecisionTests.Failure(kind: "busy", message: "the round is held")
            ]
        )

        #expect(
            VotingRoundHostDecision.decide(report)
                == VotingRoundHostDecision.rerunFailedBundles(message: "connection reset", seconds: 2)
        )
    }

    @Test func aProtocolFailureStillShowsTheSheet() throws {
        let report = try Self.makeReport(
            kind: "failures",
            failures: [VotingRoundHostDecisionTests.Failure(kind: "protocol", message: "unexpected answer")]
        )

        #expect(
            VotingRoundHostDecision.decide(report)
                == VotingRoundHostDecision.failed(message: "unexpected answer", retryable: true)
        )
    }

    @Test func aStorageFailureStillShowsTheSheet() throws {
        let report = try Self.makeReport(
            kind: "failures",
            failures: [VotingRoundHostDecisionTests.Failure(kind: "storage", message: "disk full")]
        )

        #expect(
            VotingRoundHostDecision.decide(report)
                == VotingRoundHostDecision.failed(message: "disk full", retryable: true)
        )
    }

    @Test func anInvalidInputFailureIsNotRetryable() throws {
        let report = try Self.makeReport(
            kind: "failures",
            failures: [VotingRoundHostDecisionTests.Failure(kind: "invalid_input", message: "choice out of range")]
        )

        #expect(
            VotingRoundHostDecision.decide(report)
                == VotingRoundHostDecision.failed(message: "choice out of range", retryable: false)
        )
    }

    @Test func failuresWithoutARecordStillFail() throws {
        let report = try Self.makeReport(kind: "failures")

        #expect(
            VotingRoundHostDecision.decide(report)
                == VotingRoundHostDecision.failed(message: "voting failed", retryable: false)
        )
    }

    @Test func aChainTerminalWithoutAnOutcomeStillExplainsItself() throws {
        let report = try Self.makeReport(kind: "chain_terminal")

        #expect(
            VotingRoundHostDecision.decide(report)
                == VotingRoundHostDecision.chainTerminal(message: "submission ended without confirmation")
        )
    }

    // MARK: - Report factory

    /// One failure record's wire fields, as much of them as these tests need.
    struct Failure {
        let kind: String
        let message: String
    }

    private static func makeReport(
        kind: String,
        openProposals: [UInt32] = [],
        unrosteredIntents: [UInt32] = [],
        bundles: [UInt32] = [],
        chainOutcomeKind: String? = nil,
        diagnostic: String? = nil,
        failures: [Failure] = []
    ) throws -> VotingRoundRunReport {
        var quiescence: [String: Any] = [
            "kind": kind,
            "open_proposals": openProposals.map { Int($0) },
            "unrostered_intents": unrosteredIntents.map { Int($0) },
            "bundles": bundles.map { Int($0) }
        ]
        if let chainOutcomeKind {
            var outcome: [String: Any] = ["kind": chainOutcomeKind]
            if let diagnostic {
                outcome["diagnostic"] = ["message": diagnostic]
            }
            quiescence["chain_outcome"] = outcome
        }
        let report: [String: Any] = [
            "quiescence": quiescence,
            "tally": [
                "completed_proposals": 0,
                "total_proposals": 0,
                "remaining_obligations": 0
            ],
            "failures": failures.map { failure in
                ["failure": ["kind": failure.kind, "message": failure.message]]
            }
        ]

        let data = try JSONSerialization.data(withJSONObject: report)
        return try JSONDecoder().decode(VotingRoundRunReport.self, from: data)
    }
}
#endif
