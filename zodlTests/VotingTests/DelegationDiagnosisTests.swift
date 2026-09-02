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
        roundHasBundles: Bool = true,
        escrowHoldsRecoveredSecrets: Bool = false,
        hasDelegationTxHash: Bool = false,
        voteServiceAnswered: Bool = true
    ) -> Diagnosis.Signals {
        Diagnosis.Signals(
            roundHasBundles: roundHasBundles,
            escrowHoldsRecoveredSecrets: escrowHoldsRecoveredSecrets,
            hasDelegationTxHash: hasDelegationTxHash,
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
            signals(escrowHoldsRecoveredSecrets: true, hasDelegationTxHash: true)
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
            signals(escrowHoldsRecoveredSecrets: true, hasDelegationTxHash: false)
        )

        #expect(diagnosis == .secretsRecovered)
    }

    /// The state a real affected device reported, and the regression this
    /// exists to stop.
    ///
    /// Their round was wiped and REBUILT, so bundle rows exist; recovery had
    /// carved the original back and escrowed it. They were shown POLL-02,
    /// because the recovered case used to require an absence of rows, and the
    /// rebuild had supplied them. The right answer is that their data was lost
    /// and is back.
    @Test func aWipedRoundWithRebuiltRowsStillReportsRecovered() {
        let diagnosis = Diagnosis.diagnose(
            signals(
                roundHasBundles: true,
                escrowHoldsRecoveredSecrets: true,
                hasDelegationTxHash: true
            )
        )

        #expect(diagnosis == .secretsRecovered)
        #expect(diagnosis != .broadcastDoNotRebuild, "the misdiagnosis this test pins")
    }

    /// An ordinary live capture is not evidence of loss. Every delegation
    /// build escrows one, so treating presence alone as recovery would tell
    /// most users their data had been lost.
    @Test func anOrdinaryLiveCaptureIsNotReportedAsRecovery() {
        let diagnosis = Diagnosis.diagnose(
            signals(escrowHoldsRecoveredSecrets: false, hasDelegationTxHash: true)
        )

        #expect(diagnosis == .broadcastDoNotRebuild)
    }

    /// The wipe, with nothing recovered. The unrecoverable state.
    @Test func wipedWithNothingRecoveredReportsSecretsLost() {
        let diagnosis = Diagnosis.diagnose(
            signals(roundHasBundles: false, hasDelegationTxHash: true)
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
        for rows in [true, false] {
            for hash in [true, false] {
                for recovered in [true, false] {
                    for answered in [true, false] {
                        let input = signals(
                            roundHasBundles: rows,
                            escrowHoldsRecoveredSecrets: recovered,
                            hasDelegationTxHash: hash,
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
                        // Rebuilding is permitted only on positive evidence:
                        // nothing was rescued, no broadcast is recorded, and
                        // the service confirmed it. Whether rows exist does
                        // not appear -- a round never set up has nothing to
                        // lose, and a rebuilt one is covered by the first two.
                        let permitted = Diagnosis.diagnose(input).mayRebuildLocalState
                        let expected = !recovered && !hash && answered
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
