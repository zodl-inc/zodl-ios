#if VOTING_ENABLED
import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

/// What an affected voter actually reads when the poll fails.
///
/// `DelegationDiagnosisTests` covers the classification; this covers the
/// delivery, which is the part that was missing. A correct diagnosis nothing
/// displays would not have helped the user we are about to hand a build to.
@Suite struct PipelineFailureMessageTests {
    /// The raw error an incomplete delegation setup produces, from the report
    /// quoted in MOB-1802.
    private let incompleteSetup = NSError(
        domain: "voting",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey:
            "build_and_prove_delegation failed: invalid input: no alpha for round=abc, "
            + "bundle=0 (Invalid column type Null at index: 0, name: alpha)"]
    )

    /// Exercises the classifier through the message layer WITHOUT naming a
    /// recovery type, so this suite keeps compiling once the recovery code is
    /// deleted. `recovered` stands in for the signal the gated call site
    /// gathers; when that call site goes, it is simply always false.
    private func message(
        error: Error,
        recovered: Bool = false,
        txHash: VotingTxHashLookup,
        bundleCount: UInt32
    ) async -> String {
        guard VotingErrorMapper.isIncompleteDelegationSetup(error.localizedDescription) else {
            return VotingErrorMapper.userFriendlyMessage(from: error)
        }

        var crypto = VotingCryptoClient.testValue
        crypto.getDelegationTxHash = { _, _ in txHash }
        crypto.getBundleCount = { _ in bundleCount }

        return await DelegationDiagnosis.forRound(
            String(repeating: "4a", count: 32),
            voteServiceAnswered: false,
            escrowHoldsRecoveredSecrets: recovered,
            crypto: crypto
        ).message
    }

    /// The state our affected user is in: the round was wiped and recovery
    /// escrowed the originals. They must be told their data is safe and NOT
    /// told to re-enter the poll.
    @Test func aWipedRoundWhoseSecretsWereRecoveredSaysSo() async {
        let shown = await message(
            error: incompleteSetup,
            recovered: true,
            txHash: .present("d0"),
            bundleCount: 3
        )

        #expect(shown == DelegationDiagnosis.secretsRecovered.message)
        #expect(shown.contains("POLL-03"))
        // The advice that caused the incident must be gone from this path.
        #expect(shown.contains("enter it again") == false)
    }

    /// Delegation on chain, secrets still present: resumable, never rebuilt.
    @Test func aBroadcastRoundWarnsAgainstReEnteringThePoll() async {
        let shown = await message(
            error: incompleteSetup,
            recovered: false,
            txHash: .present("d0"),
            bundleCount: 3
        )

        #expect(shown == DelegationDiagnosis.broadcastDoNotRebuild.message)
        #expect(shown.contains("POLL-02"))
        #expect(shown.contains("Do not leave"))
    }

    /// Wiped with nothing recovered: the unrecoverable state, and it must not
    /// masquerade as anything softer.
    @Test func aWipedRoundWithNothingRecoveredSaysItIsLost() async {
        let shown = await message(
            error: incompleteSetup,
            txHash: .present("d0"),
            bundleCount: 0
        )

        #expect(shown == DelegationDiagnosis.secretsLost.message)
        #expect(shown.contains("POLL-04"))
    }

    /// No evidence of a broadcast, and this path never asked the service, so
    /// it must not claim rebuilding is safe.
    @Test func noEvidenceOfABroadcastIsUndeterminedNotSafeToRebuild() async {
        let shown = await message(
            error: incompleteSetup,
            txHash: .notFound,
            bundleCount: 3
        )

        #expect(shown == DelegationDiagnosis.undetermined.message)
        #expect(shown.contains("POLL-05"))
        #expect(shown.contains("enter it again") == false)
    }

    /// Everything else keeps the existing mapping; the diagnosis must not
    /// swallow unrelated failures.
    @Test func anUnrelatedFailureKeepsItsOwnMessage() async {
        let spent = NSError(
            domain: "voting", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "nullifier already spent"]
        )

        let shown = await message(
            error: spent, recovered: true, txHash: .present("d0"), bundleCount: 0
        )

        #expect(shown == String(localizable: .coinVoteStoreUserErrorNullifierAlreadySpent))
        #expect(shown.contains("POLL-") == false)
    }

    /// The exact state a real affected device reported: wiped, rebuilt (so
    /// rows exist), and recovery had already escrowed the original. It showed
    /// POLL-02. It must show POLL-03.
    @Test func theRealAffectedDeviceStateReportsRecovered() async {
        let shown = await message(
            error: incompleteSetup,
            recovered: true,
            txHash: .present("16eef7eb"),
            bundleCount: 1
        )

        #expect(shown.contains("POLL-03"))
        #expect(shown.contains("POLL-02") == false)
    }
}
#endif
