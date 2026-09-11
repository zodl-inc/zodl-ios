#if VOTING_ENABLED
import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

// Drives a TCA coordinator that touches process-global `@Shared` state (e.g. `selectedWalletAccount`)
// and uses plain `Store`s for the async cases, so the suite is serialized to match XCTest's previous
// serial execution and avoid cross-test races on that shared state.
@Suite(.serialized) struct VotingCoordFlowCoordinatorTests {
    @Test func batchVoteSubmittedMovesDraftIntoSubmittedVotes() {
        let metadata = VotingMetadataBox()
        var state = VotingCoordFlow.State()
        state.roundCache[roundId] = roundSession(
            drafts: [
                1: .option(0),
                2: .option(1)
            ]
        )

        withDependencies {
            $0.votingMetadata = votingMetadataClient(metadata)
        } operation: {
            _ = VotingCoordFlow().reduceBatchVoteSubmitted(
                &state,
                roundId: roundId,
                proposalId: 1,
                choice: .option(0)
            )
        }

        let session = tryUnwrap(state.roundCache[roundId])
        #expect(session.draftVotes == [2: .option(1)])
        #expect(session.votes == [1: .option(0)])
        #expect(metadata.drafts[roundId] == ["2": 1])
        #expect(metadata.submittedVotes[roundId] == ["1": 0])
    }

    @Test func batchSubmissionCompletedAcceptsPartialBallotWhenDraftsAreDrained() {
        let metadata = VotingMetadataBox()
        var state = VotingCoordFlow.State()
        state.roundCache[roundId] = roundSession(
            votingWeight: 50_000_000,
            votes: [
                1: .option(0),
                3: .option(1)
            ]
        )

        withDependencies {
            $0.votingMetadata = votingMetadataClient(metadata)
        } operation: {
            _ = VotingCoordFlow().reduceBatchSubmissionCompleted(
                &state,
                roundId: roundId,
                successCount: 2,
                failCount: 0
            )
        }

        let session = tryUnwrap(state.roundCache[roundId])
        #expect(session.batchSubmissionStatus == .completed(successCount: 2))
        #expect(session.voteRecord?.votingWeight == 50_000_000)
        #expect(session.voteRecord?.proposalCount == 2)
        #expect(state.voteRecords[roundId]?.proposalCount == 2)
        #expect(metadata.records[roundId]?.proposalCount == 2)
    }

    @Test func batchSubmissionCompletedFailsWhenDraftsRemain() {
        var state = VotingCoordFlow.State()
        state.roundCache[roundId] = roundSession(
            drafts: [2: .option(1)],
            votes: [1: .option(0)]
        )

        _ = VotingCoordFlow().reduceBatchSubmissionCompleted(
            &state,
            roundId: roundId,
            successCount: 1,
            failCount: 0
        )

        let session = tryUnwrap(state.roundCache[roundId])
        #expect(
            session.batchSubmissionStatus == .submissionFailed(
                error: String(localizable: .coinVoteSubmissionGenericBatchFailure),
                submittedCount: 1,
                totalCount: 2
            )
        )
        #expect(session.voteRecord == nil)
    }

    @Test func batchSubmissionCompletedFailsWhenVoteErrorsExist() {
        var session = roundSession(votes: [1: .option(0)])
        session.batchVoteErrors = [2: "server unavailable"]
        var state = VotingCoordFlow.State()
        state.roundCache[roundId] = session

        _ = VotingCoordFlow().reduceBatchSubmissionCompleted(
            &state,
            roundId: roundId,
            successCount: 1,
            failCount: 0
        )

        let updated = tryUnwrap(state.roundCache[roundId])
        #expect(
            updated.batchSubmissionStatus == .submissionFailed(
                error: "server unavailable",
                submittedCount: 1,
                totalCount: 1
            )
        )
        #expect(updated.voteRecord == nil)
    }

    @Test func batchSubmissionProgressClearsPreviousSubmissionStep() {
        var session = roundSession()
        session.voteSubmissionStep = .sendingShares
        session.currentVoteBundleIndex = 0
        var state = VotingCoordFlow.State()
        state.roundCache[roundId] = session

        _ = VotingCoordFlow().reduceBatchSubmissionProgress(
            &state,
            roundId: roundId,
            currentIndex: 0,
            totalCount: 1,
            proposalId: 1
        )

        let updated = tryUnwrap(state.roundCache[roundId])
        #expect(updated.batchSubmissionStatus == .submitting(currentIndex: 0, totalCount: 1, currentProposalId: 1))
        #expect(updated.submittingProposalId == 1)
        #expect(updated.isSubmittingVote)
        #expect(updated.voteSubmissionStep == nil)
        #expect(updated.currentVoteBundleIndex == nil)
    }

    @Test func authenticationSucceededStartsSoftwareDelegationAtSubmitTime() {
        var session = RoundSession(roundId: activeRoundId)
        session.bundleCount = 1
        session.draftVotes = [1: .option(0)]
        var state = VotingCoordFlow.State()
        state.roundCache[activeRoundId] = session
        state.allRounds = [RoundListItem(roundNumber: 1, session: votingSession())]

        _ = VotingCoordFlow().reduceAuthenticationSucceeded(&state, roundId: activeRoundId)

        let updated = tryUnwrap(state.roundCache[activeRoundId])
        #expect(!state.pendingBatchSubmission)
        #expect(updated.batchSubmissionStatus == .authorizing)
        #expect(updated.voteSubmissionStep == .authorizingVote)
        #expect(updated.delegationProofStatus == .generating(progress: 0))
    }

    // Finding #8 (CHP.md): a proposal already confirmed on-chain but missing
    // its share delegations has already been moved out of `draftVotes` (see
    // `.submittedVotesLoaded`), so with the old bare `draftVotes.isEmpty`
    // gate this reducer bailed with `.none` and the round was permanently
    // stuck — the submit CTA looked present but did nothing.
    // `undeliveredShareProposalIds` alone must be enough to let the batch
    // submission `.run` effect start, reusing the on-chain choice already
    // known from `session.votes`.
    @Test func authenticationSucceededProcessesUndeliveredShareProposalWithEmptyDrafts() {
        var session = RoundSession(roundId: activeRoundId)
        session.bundleCount = 1
        session.votes = [1: .option(0)]
        session.undeliveredShareProposalIds = [1]
        var state = VotingCoordFlow.State()
        state.roundCache[activeRoundId] = session
        state.allRounds = [RoundListItem(roundNumber: 1, session: votingSession())]

        _ = VotingCoordFlow().reduceAuthenticationSucceeded(&state, roundId: activeRoundId)

        let updated = tryUnwrap(state.roundCache[activeRoundId])
        #expect(!state.pendingBatchSubmission)
        #expect(updated.batchSubmissionStatus == .authorizing)
        #expect(updated.voteSubmissionStep == .authorizingVote)
        #expect(updated.delegationProofStatus == .generating(progress: 0))
    }

    // The literal Finding #8 shape: a vote record landed on-chain
    // (`submitted == true`) but the helper-server share delegation was never
    // recorded for it at all — the same pairing Task 8F's in-loop
    // `bundlesWithRecordedShares` check uses, generalized across the whole
    // round.
    @Test func undeliveredShareProposalIdsFlagsSubmittedProposalWithZeroShareDelegations() {
        let records = [
            VoteRecord(proposalId: 1, bundleIndex: 0, choice: .option(0), submitted: true)
        ]

        let result = VotingCoordFlow.undeliveredShareProposalIds(records: records, shareDelegations: [])

        #expect(result == [1])
    }

    // A bundle that's still mid-flight (never reached `markVoteSubmitted`) is
    // still a live draft and must not be double-counted as a recovery
    // target — it's already reachable through `draftVotes`.
    @Test func undeliveredShareProposalIdsIgnoresProposalsNeverSubmitted() {
        let records = [
            VoteRecord(proposalId: 2, bundleIndex: 0, choice: .option(1), submitted: false)
        ]

        let result = VotingCoordFlow.undeliveredShareProposalIds(records: records, shareDelegations: [])

        #expect(result.isEmpty)
    }

    @Test func delegationFailureDuringBatchAuthorizationShowsAuthorizationFailure() {
        var session = roundSession()
        session.bundleCount = 2
        session.currentKeystoneBundleIndex = 1
        session.keystoneBundleSignatures = [signature(byte: 1)]
        session.keystoneSigningStatus = .awaitingSignature
        session.delegationProofStatus = .generating(progress: 0.5)
        session.isDelegationProofInFlight = true
        session.batchSubmissionStatus = .authorizing
        session.voteSubmissionStep = .authorizingVote
        session.currentVoteBundleIndex = 0
        var state = VotingCoordFlow.State()
        state.isKeystoneUser = true
        state.pendingBatchSubmission = true
        state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
        state.roundCache[roundId] = session

        _ = VotingCoordFlow().reduceDelegationProofFailed(
            &state,
            roundId: roundId,
            error: "nullifier already spent"
        )

        let updated = tryUnwrap(state.roundCache[roundId])
        #expect(updated.delegationProofStatus == .failed("nullifier already spent"))
        #expect(!updated.isDelegationProofInFlight)
        #expect(!state.pendingBatchSubmission)
        #expect(updated.batchSubmissionStatus == .authorizationFailed(error: "nullifier already spent"))
        #expect(updated.voteSubmissionStep == nil)
        #expect(updated.currentVoteBundleIndex == nil)
        #expect(updated.currentKeystoneBundleIndex == 0)
        #expect(updated.keystoneBundleSignatures.isEmpty)
        #expect(updated.keystoneSigningStatus == .failed("nullifier already spent"))
    }

    @Test func intermediateKeystoneSignatureAdvancesToNextBundle() {
        var session = roundSession()
        session.bundleCount = 2
        session.currentKeystoneBundleIndex = 0
        session.keystoneSigningStatus = .awaitingSignature
        var state = VotingCoordFlow.State()
        state.roundCache[roundId] = session

        _ = VotingCoordFlow().reduceKeystoneBundleSignatureStored(
            &state,
            roundId: roundId,
            signature: signature(byte: 1),
            bundleIndex: 0,
            bundleCount: 2
        )

        let updated = tryUnwrap(state.roundCache[roundId])
        #expect(updated.currentKeystoneBundleIndex == 1)
        #expect(updated.keystoneBundleSignatures == [signature(byte: 1)])
        #expect(updated.keystoneSigningStatus == .idle)
        #expect(!updated.isDelegationProofInFlight)
        #expect(updated.pendingVotingPczt == nil)
        #expect(updated.pendingUnsignedDelegationPczt == nil)
    }

    @Test func finalKeystoneSignatureMovesToFinalizingAuthorization() {
        var session = roundSession()
        session.bundleCount = 2
        session.currentKeystoneBundleIndex = 1
        session.keystoneBundleSignatures = [signature(byte: 1, bundleIndex: 0)]
        session.keystoneSigningStatus = .awaitingSignature
        var state = VotingCoordFlow.State()
        state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
        state.roundCache[roundId] = session

        _ = VotingCoordFlow().reduceKeystoneBundleSignatureStored(
            &state,
            roundId: roundId,
            signature: signature(byte: 2, bundleIndex: 1),
            bundleIndex: 1,
            bundleCount: 2
        )

        let updated = tryUnwrap(state.roundCache[roundId])
        #expect(updated.keystoneBundleSignatures == [
            signature(byte: 1, bundleIndex: 0),
            signature(byte: 2, bundleIndex: 1)
        ])
        #expect(updated.keystoneSigningStatus == .finalizingAuthorization)
        #expect(updated.delegationProofStatus == .generating(progress: 0))
        #expect(updated.isDelegationProofInFlight)
        #expect(updated.batchSubmissionStatus == .authorizing)
        #expect(updated.voteSubmissionStep == .authorizingVote)
        #expect(!isDelegationSigningTop(state))
    }

    @Test func skippingRemainingKeystoneBundlesKeepsOnlySignedWeight() {
        var session = roundSession(
            votingWeight: 100_000_000,
            notes: [
                note(value: 31_568_000, position: 0),
                note(value: 26_000_000, position: 1),
                note(value: 13_000_000, position: 2),
                note(value: 12_500_000, position: 3),
                note(value: 5_000_000, position: 4),
                note(value: 4_000_000, position: 5),
                note(value: 3_000_000, position: 6),
                note(value: 3_000_000, position: 7),
                note(value: 2_000_000, position: 8),
                note(value: 1_000_000, position: 9)
            ]
        )
        session.bundleCount = 2
        session.keystoneBundleSignatures = [signature(byte: 1)]
        var state = VotingCoordFlow.State()
        state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
        state.roundCache[roundId] = session

        _ = VotingCoordFlow().reduceSkipRemainingKeystoneBundles(&state, roundId: roundId)

        let updated = tryUnwrap(state.roundCache[roundId])
        #expect(updated.bundleCount == 1)
        #expect(updated.votingWeight == 87_500_000)
        #expect(updated.eligibleBundleCount == 2)
        #expect(updated.eligibleVotingWeight == 100_000_000)
        #expect(updated.keystoneSigningStatus == .finalizingAuthorization)
        #expect(updated.batchSubmissionStatus == .authorizing)
        #expect(updated.voteSubmissionStep == .authorizingVote)
        #expect(!isDelegationSigningTop(state))
    }

    @Test func skippingRemainingKeystoneBundlesDropsSparseRecoveredState() {
        var session = roundSession(
            votingWeight: 150_000_000,
            notes: notes(count: 15, value: 10_000_000)
        )
        session.bundleCount = 3
        session.completedKeystoneDelegationBundleIndices = [0]
        session.keystoneBundleSignatures = [signature(byte: 3, bundleIndex: 2)]
        var state = VotingCoordFlow.State()
        state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
        state.roundCache[roundId] = session

        _ = VotingCoordFlow().reduceSkipRemainingKeystoneBundles(&state, roundId: roundId)

        let updated = tryUnwrap(state.roundCache[roundId])
        #expect(updated.bundleCount == 1)
        #expect(updated.completedKeystoneDelegationBundleIndices == Set([0]))
        #expect(updated.keystoneBundleSignatures.isEmpty)
    }

    @Test func recoveredKeystoneBundleResumesAtFirstIncompleteBundle() {
        var session = roundSession()
        session.bundleCount = 2
        var state = VotingCoordFlow.State()
        state.roundCache[roundId] = session

        _ = VotingCoordFlow().coordinatorReduce().reduce(
            into: &state,
            action: .delegationBundlesRecovered(roundId: roundId, bundleIndices: [0])
        )

        let updated = tryUnwrap(state.roundCache[roundId])
        #expect(updated.completedKeystoneDelegationBundleIndices == Set([0]))
        #expect(updated.currentKeystoneBundleIndex == 1)
    }

    @Test func finalSignatureAfterRecoveredBundleMovesToFinalizingAuthorization() {
        var session = roundSession()
        session.bundleCount = 2
        session.currentKeystoneBundleIndex = 1
        session.completedKeystoneDelegationBundleIndices = [0]
        session.keystoneSigningStatus = .awaitingSignature
        var state = VotingCoordFlow.State()
        state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
        state.roundCache[roundId] = session

        _ = VotingCoordFlow().reduceKeystoneBundleSignatureStored(
            &state,
            roundId: roundId,
            signature: signature(byte: 2, bundleIndex: 1),
            bundleIndex: 1,
            bundleCount: 2
        )

        let updated = tryUnwrap(state.roundCache[roundId])
        #expect(updated.completedKeystoneDelegationBundleIndices == Set([0]))
        #expect(updated.keystoneBundleSignatures == [signature(byte: 2, bundleIndex: 1)])
        #expect(updated.keystoneSigningStatus == .finalizingAuthorization)
        #expect(updated.delegationProofStatus == .generating(progress: 0))
        #expect(updated.isDelegationProofInFlight)
        #expect(updated.batchSubmissionStatus == .authorizing)
        #expect(updated.voteSubmissionStep == .authorizingVote)
        #expect(!isDelegationSigningTop(state))
    }

    @Test func duplicateKeystoneScanIsRejectedBeforeSignatureExtraction() {
        let duplicateSighash = Data(repeating: 0x02, count: 32)
        let message = VotingCoordFlow.keystoneScanRejectionMessage(
            scannedSighash: duplicateSighash,
            expectedSighash: Data(repeating: 0x05, count: 32),
            existingSignatures: [
                signature(byte: 1, bundleIndex: 0, sighash: duplicateSighash)
            ],
            currentBundleIndex: 1,
            bundleCount: 2
        )

        #expect(message == String(localizable: .coinVoteDelegationSigningDuplicateSignature("1", "2")))
    }

    @Test func wrongKeystoneScanIsRejectedBeforeSignatureExtraction() {
        let pendingSighash = Data(repeating: 0x05, count: 32)
        let scannedSighash = Data(repeating: 0x06, count: 32)
        let message = VotingCoordFlow.keystoneScanRejectionMessage(
            scannedSighash: scannedSighash,
            expectedSighash: pendingSighash,
            existingSignatures: [],
            currentBundleIndex: 1,
            bundleCount: 2
        )

        #expect(message == String(localizable: .coinVoteDelegationSigningWrongSignature("2", "2")))
    }

    @Test func matchingKeystoneScanIsAcceptedForCurrentBundle() {
        let pendingSighash = Data(repeating: 0x05, count: 32)

        #expect(
            VotingCoordFlow.keystoneScanRejectionMessage(
                scannedSighash: pendingSighash,
                expectedSighash: pendingSighash,
                existingSignatures: [signature(byte: 1, bundleIndex: 0)],
                currentBundleIndex: 1,
                bundleCount: 2
            ) == nil
        )
    }

    @MainActor

    @Test func delegationRejectedResetsKeystoneLoopButPreservesVotes() {
        var session = roundSession(
            drafts: [2: .option(1)],
            votes: [1: .option(0)]
        )
        session.bundleCount = 2
        session.currentKeystoneBundleIndex = 1
        session.keystoneBundleSignatures = [signature(byte: 1)]
        session.keystoneSigningStatus = .awaitingSignature
        session.batchSubmissionStatus = .authorizing
        var state = VotingCoordFlow.State()
        state.pendingBatchSubmission = true
        state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
        state.roundCache[roundId] = session

        _ = VotingCoordFlow().coordinatorReduce().reduce(
            into: &state,
            action: .delegationRejected(roundId: roundId)
        )

        let updated = tryUnwrap(state.roundCache[roundId])
        #expect(updated.currentKeystoneBundleIndex == 0)
        #expect(updated.keystoneBundleSignatures.isEmpty)
        #expect(updated.keystoneSigningStatus == .idle)
        #expect(updated.batchSubmissionStatus == .idle)
        #expect(updated.draftVotes == [2: .option(1)])
        #expect(updated.votes == [1: .option(0)])
        #expect(!state.pendingBatchSubmission)
        #expect(!isDelegationSigningTop(state))
    }

    // MARK: - Round setup never deletes

    @Test func absentRoundRowIsClassifiedForInsert() {
        #expect(
            VotingCoordFlow.classifyExistingRoundRow(existingState: nil, snapshotHeight: 100)
                == .absent
        )
    }

    /// A row left behind by setup interrupted between `initRound` and
    /// `setupBundles` is reusable.
    @Test func interruptedRoundRowIsClassifiedReusable() {
        #expect(
            VotingCoordFlow.classifyExistingRoundRow(
                existingState: roundState(snapshotHeight: 100),
                snapshotHeight: 100
            ) == .reusable
        )
    }

    @Test func changedSnapshotHeightIsClassifiedAsChanged() {
        #expect(
            VotingCoordFlow.classifyExistingRoundRow(
                existingState: roundState(snapshotHeight: 100),
                snapshotHeight: 101
            ) == .parametersChanged
        )
    }

    private func roundState(snapshotHeight: UInt64) -> RoundStateInfo {
        RoundStateInfo(
            roundId: roundId,
            phase: .initialized,
            snapshotHeight: snapshotHeight,
            hotkeyAddress: nil,
            delegatedWeight: nil,
            proofGenerated: false
        )
    }

    @Test func persistedBundlesResumeInsteadOfPreparingFreshRound() {
        #expect(VotingCoordFlow.shouldResumePersistedRound(existingBundleCount: 1))
        #expect(!VotingCoordFlow.shouldResumePersistedRound(existingBundleCount: 0))
    }

    @Test func acceptedVotingTransactionDoesNotQueryRecovery() async throws {
        let recorder = RecoveryOrderRecorder()
        var votingAPI = VotingAPIClient()
        votingAPI.fetchTxConfirmation = { txHash in
            await recorder.record("fetch:\(txHash)")
            return nil
        }

        let accepted = try await VotingCoordFlow.isAcceptedVotingTransaction(
            TxResult(txHash: "accepted-tx", code: 0),
            votingAPI: votingAPI,
            maxRecoveryAttempts: 1,
            retryDelay: .zero
        )

        #expect(accepted)
        #expect(await recorder.events().isEmpty)
    }

    @Test func spentNullifierRecoversWhenExactTransactionIsConfirmed() async throws {
        let recorder = RecoveryOrderRecorder()
        var votingAPI = VotingAPIClient()
        votingAPI.fetchTxConfirmation = { txHash in
            await recorder.record("fetch:\(txHash)")
            return TxConfirmation(height: 12, code: 0)
        }

        let accepted = try await VotingCoordFlow.isAcceptedVotingTransaction(
            TxResult(
                txHash: "duplicate-tx",
                code: 1,
                log: "nullifier already spent: abc123"
            ),
            votingAPI: votingAPI,
            maxRecoveryAttempts: 1,
            retryDelay: .zero
        )

        #expect(accepted)
        #expect(await recorder.events() == ["fetch:duplicate-tx"])
    }

    @Test func spentNullifierFailsWhenExactTransactionIsNotConfirmed() async throws {
        let recorder = RecoveryOrderRecorder()
        var votingAPI = VotingAPIClient()
        votingAPI.fetchTxConfirmation = { txHash in
            await recorder.record("fetch:\(txHash)")
            return nil
        }

        let accepted = try await VotingCoordFlow.isAcceptedVotingTransaction(
            TxResult(
                txHash: "missing-tx",
                code: 1,
                log: "Nullifier was already spent"
            ),
            votingAPI: votingAPI,
            maxRecoveryAttempts: 1,
            retryDelay: .zero
        )

        #expect(!accepted)
        #expect(await recorder.events() == ["fetch:missing-tx"])
    }

    @Test func spentNullifierFailsWhenExactTransactionHasNonzeroCode() async throws {
        let recorder = RecoveryOrderRecorder()
        var votingAPI = VotingAPIClient()
        votingAPI.fetchTxConfirmation = { txHash in
            await recorder.record("fetch:\(txHash)")
            return TxConfirmation(height: 12, code: 7, log: "execution failed")
        }

        let accepted = try await VotingCoordFlow.isAcceptedVotingTransaction(
            TxResult(
                txHash: "rejected-tx",
                code: 1,
                log: "nullifier already spent"
            ),
            votingAPI: votingAPI,
            maxRecoveryAttempts: 1,
            retryDelay: .zero
        )

        #expect(!accepted)
        #expect(await recorder.events() == ["fetch:rejected-tx"])
    }

    @Test func spentNullifierWithoutHashDoesNotQueryRecovery() async throws {
        let recorder = RecoveryOrderRecorder()
        var votingAPI = VotingAPIClient()
        votingAPI.fetchTxConfirmation = { txHash in
            await recorder.record("fetch:\(txHash)")
            return TxConfirmation(height: 12, code: 0)
        }

        let accepted = try await VotingCoordFlow.isAcceptedVotingTransaction(
            TxResult(txHash: "", code: 1, log: "nullifier already spent"),
            votingAPI: votingAPI,
            maxRecoveryAttempts: 1,
            retryDelay: .zero
        )

        #expect(!accepted)
        #expect(await recorder.events().isEmpty)
    }

    @Test func spentNullifierRetriesWhileExactTransactionIsBeingIndexed() async throws {
        let recorder = RecoveryOrderRecorder()
        var votingAPI = VotingAPIClient()
        votingAPI.fetchTxConfirmation = { txHash in
            let attempt = await recorder.recordAndCount("fetch:\(txHash)")
            return attempt == 2 ? TxConfirmation(height: 12, code: 0) : nil
        }

        let accepted = try await VotingCoordFlow.isAcceptedVotingTransaction(
            TxResult(txHash: "indexing-tx", code: 1, log: "nullifier already spent"),
            votingAPI: votingAPI,
            maxRecoveryAttempts: 3,
            retryDelay: .zero
        )

        #expect(accepted)
        #expect(await recorder.events() == ["fetch:indexing-tx", "fetch:indexing-tx"])
    }

    @Test func unrelatedTransactionRejectionDoesNotQueryRecovery() async throws {
        let recorder = RecoveryOrderRecorder()
        var votingAPI = VotingAPIClient()
        votingAPI.fetchTxConfirmation = { txHash in
            await recorder.record("fetch:\(txHash)")
            return TxConfirmation(height: 12, code: 0)
        }

        let accepted = try await VotingCoordFlow.isAcceptedVotingTransaction(
            TxResult(txHash: "failed-tx", code: 1, log: "invalid proof"),
            votingAPI: votingAPI,
            maxRecoveryAttempts: 1,
            retryDelay: .zero
        )

        #expect(!accepted)
        #expect(await recorder.events().isEmpty)
    }

    @Test func delegationVanPositionRecoversLegacyBase64DecodedLeafIndex() {
        let decodedLeafIndex = String(decoding: Data([0xdf, 0xbe, 0x77]), as: UTF8.self)
        #expect(Data(decodedLeafIndex.utf8).base64EncodedString() == "3753")
        let confirmation = TxConfirmation(
            height: 1,
            code: 0,
            events: [
                TxEvent(
                    type: "delegate_vote",
                    attributes: [TxEventAttribute(key: "leaf_index", value: decodedLeafIndex)]
                )
            ]
        )

        #expect(VotingCoordFlow.delegationVanPosition(from: confirmation) == 3753)
    }

    @Test func delegationVanPositionRejectsNonCanonicalBase64DecodedLeafIndex() {
        // The server formats positions with %d, so a leading-zero re-encode
        // such as "0400" cannot be a genuine mangle and must fail closed.
        let decodedLeafIndex = String(decoding: Data([0xd3, 0x8d, 0x34]), as: UTF8.self)
        #expect(Data(decodedLeafIndex.utf8).base64EncodedString() == "0400")
        let confirmation = TxConfirmation(
            height: 1,
            code: 0,
            events: [
                TxEvent(
                    type: "delegate_vote",
                    attributes: [TxEventAttribute(key: "leaf_index", value: decodedLeafIndex)]
                )
            ]
        )

        #expect(VotingCoordFlow.delegationVanPosition(from: confirmation) == nil)
    }

    @Test func delegationVanPositionRejectsMalformedAsciiLeafIndex() {
        let confirmation = TxConfirmation(
            height: 1,
            code: 0,
            events: [
                TxEvent(
                    type: "delegate_vote",
                    attributes: [TxEventAttribute(key: "leaf_index", value: "not-a-position")]
                )
            ]
        )

        #expect(VotingCoordFlow.delegationVanPosition(from: confirmation) == nil)
    }

    // MARK: - Round resume decision (MOB-1802)

    // Row 1 of the decision table: one conclusive `.registered` probe wins outright, even
    // next to inconclusive ones — and the reused set is exactly the registered bundles, so
    // the bundles we couldn't confirm are never silently treated as ready.
    @Test func resumeDecisionPrefersRegisteredBundles() {
        let decision = VotingCoordFlow.roundResumeDecision(
            probes: [0: DelegationRegistrationProbe.registered(vanPosition: 7), 1: DelegationRegistrationProbe.unknown],
            savedSignatureCount: 0,
            anyLocalDelegationTxHash: false
        )

        #expect(decision == RoundResumeDecision.reuseRecovered(recoveredIndices: [0]))
    }

    // Row 2: probes that all came back inconclusive are not evidence of anything, so saved
    // Keystone signatures alone keep the round's rows alive — wiping them here is exactly
    // the wedge (alpha/rk gone, signatures restored, "Invalid column type Null … alpha").
    @Test func resumeDecisionResumesInPlaceWithSignaturesAndUnknownProbes() {
        let decision = VotingCoordFlow.roundResumeDecision(
            probes: [0: DelegationRegistrationProbe.unknown, 1: DelegationRegistrationProbe.unknown],
            savedSignatureCount: 2,
            anyLocalDelegationTxHash: false
        )

        #expect(decision == RoundResumeDecision.resumeInPlace)
    }

    // Row 2 again, from the other side: a locally cached delegation TX hash means this
    // device already broadcast a registration. Even a conclusive `.notRegistered` for that
    // bundle only rules out *reuse* — it never licenses destroying the local rows.
    @Test func resumeDecisionResumesInPlaceWithLocalTxHashEvenWhenChainSaysFailed() {
        let decision = VotingCoordFlow.roundResumeDecision(
            probes: [0: DelegationRegistrationProbe.notRegistered],
            savedSignatureCount: 0,
            anyLocalDelegationTxHash: true
        )

        #expect(decision == RoundResumeDecision.resumeInPlace)
    }

    // Row 3: nothing registered, nothing signed, nothing broadcast — there is genuinely
    // nothing to lose, so the old destructive path stays available for real fresh starts.
    @Test func resumeDecisionFreshRoundWhenNothingRecoverable() {
        let decision = VotingCoordFlow.roundResumeDecision(
            probes: [0: DelegationRegistrationProbe.unknown, 1: DelegationRegistrationProbe.notRegistered],
            savedSignatureCount: 0,
            anyLocalDelegationTxHash: false
        )

        #expect(decision == RoundResumeDecision.freshRound)
    }

    // MARK: - Stored Keystone signature validation (MOB-1802 Fix C)

    // A stored signature covers one specific ZIP-244 sighash; when the provider echoes back
    // exactly that sighash for the signature's bundle, the signature is still trustworthy.
    @Test func validatedStoredSignaturesKeepsMatchingSighash() async {
        let sighash = Data(repeating: 0xAA, count: 32)
        let signature = KeystoneBundleSignatureInfo(
            bundleIndex: 0,
            sig: Data(repeating: 0x01, count: 64),
            sighash: sighash,
            rk: Data(repeating: 0x02, count: 32)
        )

        let result = await VotingCoordFlow.validatedStoredSignatures([signature]) { _ in sighash }

        #expect(result == [signature])
    }

    // The bundle's delegation setup was rebuilt (or never matched) since the signature was
    // captured — the provider's current sighash disagrees with what the signature covers, so
    // trusting it would feed a stale signature into `build_and_prove_delegation`. Drop it; the
    // bundle re-enters the signing queue via `firstIncompleteKeystoneBundleIndex`.
    @Test func validatedStoredSignaturesDropsMismatchedSighash() async {
        let signature = KeystoneBundleSignatureInfo(
            bundleIndex: 0,
            sig: Data(repeating: 0x01, count: 64),
            sighash: Data(repeating: 0xAA, count: 32),
            rk: Data(repeating: 0x02, count: 32)
        )

        let result = await VotingCoordFlow.validatedStoredSignatures([signature]) { _ in
            Data(repeating: 0xBB, count: 32)
        }

        #expect(result.isEmpty)
    }

    // A thrown lookup means the bundle's delegation setup is incomplete or missing — exactly
    // the "Invalid column type Null … alpha" shape from the field report. That is never
    // evidence the signature is valid, so it must drop, not propagate or default to trusting it.
    @Test func validatedStoredSignaturesDropsWhenProviderThrows() async {
        let signature = KeystoneBundleSignatureInfo(
            bundleIndex: 0,
            sig: Data(repeating: 0x01, count: 64),
            sighash: Data(repeating: 0xAA, count: 32),
            rk: Data(repeating: 0x02, count: 32)
        )

        let result = await VotingCoordFlow.validatedStoredSignatures([signature]) { _ in
            throw URLError(URLError.Code.badServerResponse)
        }

        #expect(result.isEmpty)
    }

    // Mixed bundle set: the middle signature's sighash no longer matches while its neighbors
    // still do. Survivors must be exactly the matches, in their original relative order — a
    // dropped middle bundle must not shift or reorder the ones that still validate.
    @Test func validatedStoredSignaturesKeepsOnlyMatchesInOrder() async {
        let matchingSighashes: [UInt32: Data] = [
            0: Data(repeating: 0xAA, count: 32),
            2: Data(repeating: 0xCC, count: 32)
        ]
        let signature0 = KeystoneBundleSignatureInfo(
            bundleIndex: 0,
            sig: Data(repeating: 0x01, count: 64),
            sighash: Data(repeating: 0xAA, count: 32),
            rk: Data(repeating: 0x02, count: 32)
        )
        let signature1 = KeystoneBundleSignatureInfo(
            bundleIndex: 1,
            sig: Data(repeating: 0x01, count: 64),
            sighash: Data(repeating: 0xBB, count: 32),
            rk: Data(repeating: 0x02, count: 32)
        )
        let signature2 = KeystoneBundleSignatureInfo(
            bundleIndex: 2,
            sig: Data(repeating: 0x01, count: 64),
            sighash: Data(repeating: 0xCC, count: 32),
            rk: Data(repeating: 0x02, count: 32)
        )

        let result = await VotingCoordFlow.validatedStoredSignatures(
            [signature0, signature1, signature2]
        ) { bundleIndex in
            matchingSighashes[bundleIndex] ?? Data(repeating: 0xFF, count: 32)
        }

        #expect(result == [signature0, signature2])
    }

    // MARK: - Stored-signature reconciliation (persisted row cleanup)

    // The field-report shape: a persisted signature whose bundle setup is incomplete (the
    // sighash readback throws on the missing alpha/pczt_sighash). Dropping it from memory
    // alone is not enough — the persisted row shields the bundle from `resetSessionState`'s
    // guarded cleanup, so the dead setup would survive and re-wedge on the next signing
    // entry. The row must be deleted and the signature excluded.
    @Test func reconcileClearsPersistedRowWhenSetupIsIncomplete() async throws {
        let signature = KeystoneBundleSignatureInfo(
            bundleIndex: 3,
            sig: Data(repeating: 0x01, count: 64),
            sighash: Data(repeating: 0xAA, count: 32),
            rk: Data(repeating: 0x02, count: 32)
        )
        let cleared = LockIsolated<[UInt32]>([])

        let result = try await VotingCoordFlow.reconcileStoredSignatures(
            [signature],
            storedSighash: { _ in throw URLError(URLError.Code.badServerResponse) },
            clearSignature: { index in cleared.withValue { $0.append(index) } }
        )

        #expect(result.isEmpty)
        #expect(cleared.value == [3])
    }

    // Mixed set: only the signature whose stored sighash no longer matches loses its row;
    // the still-valid neighbor is untouched and survives.
    @Test func reconcileClearsOnlyMismatchedRows() async throws {
        let matching = KeystoneBundleSignatureInfo(
            bundleIndex: 0,
            sig: Data(repeating: 0x01, count: 64),
            sighash: Data(repeating: 0xAA, count: 32),
            rk: Data(repeating: 0x02, count: 32)
        )
        let stale = KeystoneBundleSignatureInfo(
            bundleIndex: 1,
            sig: Data(repeating: 0x01, count: 64),
            sighash: Data(repeating: 0xBB, count: 32),
            rk: Data(repeating: 0x02, count: 32)
        )
        let sighashes: [UInt32: Data] = [
            0: Data(repeating: 0xAA, count: 32),
            1: Data(repeating: 0xEE, count: 32)
        ]
        let cleared = LockIsolated<[UInt32]>([])

        let result = try await VotingCoordFlow.reconcileStoredSignatures(
            [matching, stale],
            storedSighash: { sighashes[$0] ?? Data() },
            clearSignature: { index in cleared.withValue { $0.append(index) } }
        )

        #expect(result == [matching])
        #expect(cleared.value == [1])
    }

    // All signatures validate: reconciliation must not touch any persisted row.
    @Test func reconcileClearsNothingWhenAllSignaturesMatch() async throws {
        let sighash = Data(repeating: 0xAA, count: 32)
        let signature = KeystoneBundleSignatureInfo(
            bundleIndex: 0,
            sig: Data(repeating: 0x01, count: 64),
            sighash: sighash,
            rk: Data(repeating: 0x02, count: 32)
        )
        let cleared = LockIsolated<[UInt32]>([])

        let result = try await VotingCoordFlow.reconcileStoredSignatures(
            [signature],
            storedSighash: { _ in sighash },
            clearSignature: { index in cleared.withValue { $0.append(index) } }
        )

        #expect(result == [signature])
        #expect(cleared.value.isEmpty)
    }

    // A failing delete must abort the pipeline retryably (fail closed), never resume on a
    // half-reconciled signature set that still shields the bundle it failed to free.
    @Test func reconcileThrowsWhenClearFails() async {
        let signature = KeystoneBundleSignatureInfo(
            bundleIndex: 0,
            sig: Data(repeating: 0x01, count: 64),
            sighash: Data(repeating: 0xAA, count: 32),
            rk: Data(repeating: 0x02, count: 32)
        )

        await #expect(throws: URLError.self) {
            _ = try await VotingCoordFlow.reconcileStoredSignatures(
                [signature],
                storedSighash: { _ in Data(repeating: 0xBB, count: 32) },
                clearSignature: { _ in throw URLError(URLError.Code.cannotWriteToFile) }
            )
        }
    }

    private let roundId = "round-1"
    private let activeRoundId = String(repeating: "aa", count: 32)

    private func roundSession(
        roundId: String? = nil,
        votingWeight: UInt64 = 0,
        drafts: [UInt32: VoteChoice] = [:],
        votes: [UInt32: VoteChoice] = [:],
        notes: [NoteInfo] = []
    ) -> RoundSession {
        var session = RoundSession(roundId: roundId ?? self.roundId)
        session.votingWeight = votingWeight
        session.draftVotes = drafts
        session.votes = votes
        session.walletNotes = notes
        return session
    }

    private func votingSession(status: SessionStatus = .active) -> VotingSession {
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
            status: status,
            createdAtHeight: 123,
            title: "Round"
        )
    }

    private func signature(
        byte: UInt8,
        bundleIndex: UInt32 = 0,
        sighash: Data? = nil
    ) -> KeystoneBundleSignature {
        KeystoneBundleSignature(
            bundleIndex: bundleIndex,
            sig: Data(repeating: byte, count: 64),
            sighash: sighash ?? Data(repeating: byte + 1, count: 32),
            rk: Data(repeating: byte + 2, count: 32)
        )
    }

    private func note(value: UInt64, position: UInt64) -> NoteInfo {
        let byte = UInt8(position % UInt64(UInt8.max))
        return NoteInfo(
            commitment: Data(repeating: byte, count: 32),
            nullifier: Data(repeating: byte, count: 32),
            value: value,
            position: position,
            diversifier: Data(repeating: byte, count: 11),
            rho: Data(repeating: byte, count: 32),
            rseed: Data(repeating: byte, count: 32),
            scope: 0,
            ufvkStr: "ufvk-\(position)"
        )
    }

    private func notes(count: Int, value: UInt64) -> [NoteInfo] {
        (0..<count).map { note(value: value, position: UInt64($0)) }
    }

    private func scanState(
        pendingSighash: Data,
        existingSignatures: [KeystoneBundleSignature] = []
    ) -> VotingCoordFlow.State {
        var session = roundSession()
        session.bundleCount = 2
        session.currentKeystoneBundleIndex = 1
        session.keystoneSigningStatus = .awaitingSignature
        session.pendingVotingPczt = Self.makeVotingPcztResult(pcztSighash: pendingSighash)
        session.pendingUnsignedDelegationPczt = Data([0x01])
        session.keystoneBundleSignatures = existingSignatures
        var state = VotingCoordFlow.State()
        state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
        state.keystoneScan = Scan.State.initial
        state.roundCache[roundId] = session
        return state
    }

    private func authorizationState(
        signatures: [KeystoneBundleSignature],
        completedBundles: Set<UInt32>,
        polyLen: UInt32? = 4096
    ) -> VotingCoordFlow.State {
        var session = roundSession(
            roundId: activeRoundId,
            notes: notes(count: 10, value: 10_000_000)
        )
        session.bundleCount = 2
        session.keystoneBundleSignatures = signatures
        session.completedKeystoneDelegationBundleIndices = completedBundles
        session.keystoneSigningStatus = .finalizingAuthorization
        session.delegationProofStatus = .generating(progress: 0)
        session.batchSubmissionStatus = .authorizing
        session.voteSubmissionStep = .authorizingVote

        var state = VotingCoordFlow.State()
        state.roundCache[activeRoundId] = session
        state.allRounds = [RoundListItem(roundNumber: 1, session: votingSession())]
        state.serviceConfig = VotingServiceConfig(
            configVersion: 1,
            voteServers: [],
            pirEndpoints: [.init(url: "https://pir.example.com", label: "pir")],
            supportedVersions: .init(pir: ["v0"], voteProtocol: "v0", tally: "v0", voteServer: "v1"),
            rounds: [:],
            pirLayout: .init(pirDepth: 1, tier0Layers: 1, tier1Layers: 1, polyLen: polyLen)
        )
        state.isKeystoneUser = true
        state.$selectedWalletAccount.withLock { $0 = keystoneWalletAccount() }
        return state
    }

    private static func makeVotingPcztResult(
        pcztSighash: Data = Data(repeating: 0x0C, count: 32)
    ) -> VotingPcztResult {
        VotingPcztResult(
            pcztBytes: Data([0x01]),
            pcztSighash: pcztSighash,
            rk: Data(repeating: 0x01, count: 32),
            alpha: Data(repeating: 0x02, count: 32),
            nfSigned: Data(repeating: 0x03, count: 32),
            cmxNew: Data(repeating: 0x04, count: 32),
            govNullifiers: [Data(repeating: 0x05, count: 32)],
            van: Data(repeating: 0x06, count: 32),
            vanCommRand: Data(repeating: 0x07, count: 32),
            dummyNullifiers: [],
            rhoSigned: Data(repeating: 0x08, count: 32),
            paddedCmx: [],
            rseedSigned: Data(repeating: 0x09, count: 32),
            rseedOutput: Data(repeating: 0x0A, count: 32),
            actionBytes: Data([0x0B]),
            actionIndex: 0
        )
    }

    private static func makeServiceConfig(
        voteServers: [VotingServiceConfig.ServiceEndpoint] = []
    ) -> VotingServiceConfig {
        VotingServiceConfig(
            configVersion: 1,
            voteServers: voteServers,
            pirEndpoints: [VotingServiceConfig.ServiceEndpoint(url: "https://pir.example.com", label: "pir")],
            supportedVersions: VotingServiceConfig.SupportedVersions(
                pir: ["v0"],
                voteProtocol: "v0",
                tally: "v0",
                voteServer: "v1"
            ),
            rounds: [:],
            pirLayout: VotingServiceConfig.PirLayout(pirDepth: 1, tier0Layers: 1, tier1Layers: 1, polyLen: 4096)
        )
    }

    private static func makeDelegationRegistration(
        rk: Data = Data(repeating: 0x01, count: 32),
        spendAuthSig: Data = Data(repeating: 0x02, count: 64),
        sighash: Data = Data(repeating: 0x08, count: 32)
    ) -> DelegationRegistration {
        DelegationRegistration(
            rk: rk,
            spendAuthSig: spendAuthSig,
            tx1Effects: Data(repeating: 0x0C, count: 821).base64EncodedString(),
            signedNoteNullifier: Data(repeating: 0x03, count: 32).base64EncodedString(),
            cmxNew: Data(repeating: 0x04, count: 32).base64EncodedString(),
            vanCmx: Data(repeating: 0x05, count: 32).base64EncodedString(),
            govNullifiers: [Data(repeating: 0x06, count: 32).base64EncodedString()],
            proof: Data(repeating: 0x07, count: 32).base64EncodedString(),
            voteRoundId: Data([0xAA, 0xBB]).base64EncodedString(),
            sighash: sighash
        )
    }

    private static func makeDelegationConfirmation(position: UInt32) -> TxConfirmation {
        TxConfirmation(
            height: 1,
            code: 0,
            events: [
                TxEvent(
                    type: "delegate_vote",
                    attributes: [.init(key: "leaf_index", value: "\(position)")]
                )
            ]
        )
    }

    private func isDelegationSigningTop(_ state: VotingCoordFlow.State) -> Bool {
        guard case .delegationSigning = state.path.last else {
            return false
        }
        return true
    }

    @MainActor
    private func waitForStore(
        // Generous ceiling, not a responsiveness claim: starved CI runners have inflated
        // trivially-fast tests to 60-120 s (unit_tests runs 33367909253, 33371909793 — the
        // 2 s budget this replaces lost twice), the poll exits the moment the condition
        // lands, and a real regression still fails, just slower.
        timeoutNanoseconds: UInt64 = 60_000_000_000,
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

    private func keystoneWalletAccount() -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: "Keystone",
            keySource: String(localizable: .accountsKeystone).lowercased(),
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        ))
    }

    private func zashiWalletAccount() -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: 0x03, count: 16)),
            name: "Zashi",
            keySource: nil,
            seedFingerprint: [UInt8](repeating: 0x04, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        ))
    }

    private func votingMetadataClient(
        _ box: VotingMetadataBox
    ) -> VotingMetadataProviderClient {
        var client = VotingMetadataProviderClient()
        client.load = { _ in }
        client.store = { _ in }
        client.resetAccount = { _ in }
        client.reset = {}
        client.loadDrafts = { box.drafts[$0] ?? [:] }
        client.setDrafts = { drafts, roundId in box.drafts[roundId] = drafts }
        client.clearDrafts = { roundId in box.drafts[roundId] = [:] }
        client.loadSubmittedVotes = { box.submittedVotes[$0] ?? [:] }
        client.setSubmittedVotes = { votes, roundId in
            box.submittedVotes[roundId] = votes
        }
        client.clearSubmittedVotes = { roundId in box.submittedVotes[roundId] = [:] }
        client.record = { box.records[$0] }
        client.allRecords = { box.records }
        client.setRecord = { record, roundId in box.records[roundId] = record }
        client.clearRecord = { roundId in box.records.removeValue(forKey: roundId) }
        return client
    }

    // MARK: - MOB-1810 health sweep hooks

    @MainActor
    @Test func votingInitializeDoesNotStartHealthSweep() async {
        let recorder = EventRecorder()
        let store = Store(initialState: VotingCoordFlow.State()) {
            VotingCoordFlow()
        } withDependencies: {
            $0.votingAPI.configureURLs = { _ in }
            $0.votingAPI.fetchAllRounds = { [] }
            $0.votingAPI.fetchZodlEndorsedRoundIds = { [] }
            $0.votingAPI.startHealthProbeSweep = { recorder.record("sweep") }
            $0.votingCrypto.openDatabase = { _, _ in }
            $0.votingCrypto.setWalletId = { _ in }
            $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
        }

        store.send(.serviceConfigLoaded(Self.makeServiceConfig()))
        await waitForStore { store.state.rootScreen == .noRounds }

        #expect(recorder.events().isEmpty)
    }
}

private final class VotingMetadataBox: @unchecked Sendable {
    var drafts: [String: [String: UInt32]] = [:]
    var submittedVotes: [String: [String: UInt32]] = [:]
    var records: [String: PersistedVotingRecord] = [:]
}

private actor RecoveryOrderRecorder {
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        recordedEvents.append(event)
    }

    func recordAndCount(_ event: String) -> Int {
        recordedEvents.append(event)
        return recordedEvents.filter { $0 == event }.count
    }

    func events() -> [String] {
        recordedEvents
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    /// Appends `event` and returns how many times it has now been recorded, letting a
    /// closure double behave differently on its first call versus later calls.
    func recordAndCount(_ event: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        recordedEvents.append(event)
        return recordedEvents.filter { $0 == event }.count
    }

    func events() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}

private enum TestError: LocalizedError {
    case unexpectedSpendAuthExtraction
    case proofFailed
    case shareRecordWriteFailed
    case delegationSetupMissing
    case delegationProofMissing
    case votingDatabaseReadFailed

    var errorDescription: String? {
        switch self {
        case .unexpectedSpendAuthExtraction:
            return "unexpected SpendAuth extraction"
        case .proofFailed:
            return "proof failed"
        case .shareRecordWriteFailed:
            return "simulated local share-record write failure"
        case .delegationSetupMissing:
            return "simulated missing persisted delegation setup"
        case .delegationProofMissing:
            return "simulated missing persisted delegation proof"
        case .votingDatabaseReadFailed:
            return "simulated voting database read failure"
        }
    }
}
#endif
