#if VOTING_ENABLED
import Testing
import Foundation
@testable import zodl_internal

/// One test per diagnosis, plus the safety property that ties them together.
///
/// The taxonomy exists because a single message covered several causes and
/// advised the one action -- leave and re-enter the poll -- that was
/// destructive for one of them. Each test below pins the state that must
/// produce each answer, and `neverPermitsARebuildWithoutPositiveEvidence`
/// pins the property that made the old behaviour an incident.
@Suite struct DelegationDiagnosisTests {
    private typealias Diagnosis = DelegationDiagnosis

    private func signals(
        hasLocalSecret: Bool = true,
        hasDelegationTxHash: Bool = false,
        escrowHoldsSecrets: Bool = false,
        voteServiceAnswered: Bool = true
    ) -> Diagnosis.Signals {
        Diagnosis.Signals(
            hasLocalSecret: hasLocalSecret,
            hasDelegationTxHash: hasDelegationTxHash,
            escrowHoldsSecrets: escrowHoldsSecrets,
            voteServiceAnswered: voteServiceAnswered
        )
    }

    // MARK: - One per case

    /// Setup interrupted before anything was submitted, confirmed by the
    /// service. The only state where discarding local data loses nothing.
    @Test func setupInterruptedBeforeBroadcastIsSafeToRebuild() {
        let diagnosis = Diagnosis.diagnose(signals())

        #expect(diagnosis == .rebuildIsSafe)
        #expect(diagnosis.rawValue == "POLL-01")
        #expect(diagnosis.mayRebuildLocalState)
    }

    /// The incident's own state: the delegation is on chain and the secrets
    /// that open it are still here. Re-entering the poll would destroy them.
    @Test func brokenSetupAfterBroadcastMustNotRebuild() {
        let diagnosis = Diagnosis.diagnose(signals(hasDelegationTxHash: true))

        #expect(diagnosis == .broadcastDoNotRebuild)
        #expect(diagnosis.rawValue == "POLL-02")
        #expect(diagnosis.mayRebuildLocalState == false)
    }

    /// After the wipe, with recovery having escrowed the originals.
    @Test func wipedButRecoveredReportsSecretsRecovered() {
        let diagnosis = Diagnosis.diagnose(
            signals(hasLocalSecret: false, hasDelegationTxHash: true, escrowHoldsSecrets: true)
        )

        #expect(diagnosis == .secretsRecovered)
        #expect(diagnosis.rawValue == "POLL-03")
        #expect(diagnosis.mayRebuildLocalState == false)
    }

    /// Recovery must take precedence over loss even when nothing on this
    /// device recorded a broadcast, because the escrowed copy is evidence a
    /// delegation existed that the wiped database can no longer show.
    @Test func escrowedSecretsOutrankAMissingTransactionHash() {
        let diagnosis = Diagnosis.diagnose(
            signals(hasLocalSecret: false, hasDelegationTxHash: false, escrowHoldsSecrets: true)
        )

        #expect(diagnosis == .secretsRecovered)
    }

    /// The wipe, with nothing recovered. The unrecoverable state.
    @Test func wipedWithNothingRecoveredReportsSecretsLost() {
        let diagnosis = Diagnosis.diagnose(
            signals(hasLocalSecret: false, hasDelegationTxHash: true)
        )

        #expect(diagnosis == .secretsLost)
        #expect(diagnosis.rawValue == "POLL-04")
        #expect(diagnosis.mayRebuildLocalState == false)
    }

    /// The trigger. An unreachable service was treated as "not delegated",
    /// which routed to the destructive rebuild; it must now be its own answer.
    @Test func anUnreachableServiceIsUndeterminedRatherThanNotDelegated() {
        let diagnosis = Diagnosis.diagnose(signals(voteServiceAnswered: false))

        #expect(diagnosis == .undetermined)
        #expect(diagnosis.rawValue == "POLL-05")
        #expect(diagnosis.mayRebuildLocalState == false)
    }

    // MARK: - The property that makes the taxonomy worth having

    /// Over every combination of signals, a rebuild is permitted ONLY on
    /// positive evidence: the service answered, it recorded no delegation, and
    /// the secrets are still present.
    ///
    /// Exhaustive rather than sampled -- four booleans is sixteen cases, so
    /// there is no reason to approximate.
    @Test func neverPermitsARebuildWithoutPositiveEvidence() {
        for secret in [true, false] {
            for hash in [true, false] {
                for escrow in [true, false] {
                    for answered in [true, false] {
                        let input = signals(
                            hasLocalSecret: secret,
                            hasDelegationTxHash: hash,
                            escrowHoldsSecrets: escrow,
                            voteServiceAnswered: answered
                        )
                        // A rebuild is permitted exactly when there is no
                        // evidence of a broadcast, the service confirmed it,
                        // and no escrowed secrets would be orphaned.
                        //
                        // Note what does NOT appear: the presence of a local
                        // secret. A round that was never set up has nothing to
                        // lose. And escrowed secrets only block a rebuild when
                        // the local copy is GONE -- the live capture in
                        // `buildVotingPczt` escrows on every delegation build,
                        // well before any broadcast, so an escrow entry on its
                        // own is an ordinary state and cannot imply one.
                        let permitted = Diagnosis.diagnose(input).mayRebuildLocalState
                        let expected = !hash && answered && !(escrow && !secret)
                        #expect(
                            permitted == expected,
                            "wrong rebuild verdict for \(input)"
                        )
                    }
                }
            }
        }
    }

    /// Every case must carry a distinct code and a message that contains it,
    /// since the code is what a voter reads back to support.
    @Test func everyDiagnosisCarriesADistinctCodeItsMessageQuotes() {
        let codes = Diagnosis.allCases.map(\.rawValue)
        #expect(Set(codes).count == codes.count, "codes must be unique")

        for diagnosis in Diagnosis.allCases {
            #expect(diagnosis.rawValue.hasPrefix("POLL-"))
            #expect(
                diagnosis.message.contains(diagnosis.rawValue),
                "\(diagnosis.rawValue) is missing from its own message"
            )
            #expect(diagnosis.message.isEmpty == false)
        }
    }
}
#endif
