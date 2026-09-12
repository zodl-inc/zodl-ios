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

    // MARK: - Chain acceptance of a voting transaction (Keystone delegation path)

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

    private func votingSession(status: SessionStatus = .active, proposalCount: Int = 1) -> VotingSession {
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
            proposals: (1...max(proposalCount, 1)).map { index in
                VotingProposal(
                    id: UInt32(index),
                    title: "Proposal \(index)",
                    description: "Description \(index)",
                    options: [
                        VoteOption(index: 0, label: "Support"),
                        VoteOption(index: 1, label: "Oppose")
                    ]
                )
            },
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

    // MARK: - Round session flow (software wallets)

    /// Entering an active round opens exactly one session, and a plan that says
    /// the round has no bundle rows yet gets them persisted before the voter
    /// reaches the ballot.
    @MainActor
    @Test func openingARoundOpensASessionAndSetsUpBundlesWhenNeeded() async {
        let recorder = EventRecorder()
        let store = Store(initialState: sessionFlowState()) {
            VotingCoordFlow()
        } withDependencies: {
            self.sessionDependencies(&$0, recorder: recorder)
            $0.votingCrypto.sessionPlan = { _ in
                // The first plan is the one the round is opened on; the second is
                // the refresh `.bundlesSetUp` asks for once the rows exist.
                let call = recorder.recordAndCount("sessionPlan")
                return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
            }
            $0.votingCrypto.setupBundles = { _ in
                recorder.record("setupBundles")
                return try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000)
            }
        }

        store.send(.startActiveRoundPipeline(roundId: activeRoundId))
        await waitForStore { self.isProposalListTop(store.state) }

        #expect(recorder.events().filter { $0 == "openRoundSession" }.count == 1)
        #expect(recorder.events().filter { $0 == "setupBundles" }.count == 1)
        #expect(store.state.roundCache[self.activeRoundId]?.bundleCount == 1)
        #expect(store.state.roundCache[self.activeRoundId]?.votingWeight == 50_000_000)
    }

    /// A wallet the crate refuses to bundle for is not an error screen: it is
    /// the polls list with the insufficient-balance sheet, so the voter can pick
    /// another round.
    @MainActor
    @Test func ineligibleWalletShowsIneligibleScreen() async {
        let recorder = EventRecorder()
        let store = Store(initialState: sessionFlowState()) {
            VotingCoordFlow()
        } withDependencies: {
            self.sessionDependencies(&$0, recorder: recorder)
            $0.votingCrypto.sessionPlan = { _ in try self.plan(needsBundleSetup: true, openProposals: [1, 2]) }
            $0.votingCrypto.setupBundles = { _ in
                recorder.record("setupBundles")
                throw VotingError(kind: .noSpendableNotes, message: "wallet holds no spendable notes")
            }
        }

        store.send(.startActiveRoundPipeline(roundId: activeRoundId))
        await waitForStore { store.state.ineligibleSheet != nil }

        #expect(store.state.path.isEmpty)
        #expect(store.state.checkingEligibilityRoundId == nil)
        #expect(store.state.ineligibleSheet?.snapshotHeight == 123)
    }

    /// The precompute runs once for the bundle that owes delegation work, and
    /// Confirm does not run it again: the run reuses the proof the crate has
    /// already persisted, so the only proving the voter waits for is the one
    /// done while they were still reading the ballot.
    @MainActor
    @Test func precomputeRunsOncePerBundleAndConfirmReusesIt() async throws {
        let recorder = EventRecorder()
        let report = try runReport(
            kind: "no_work_left",
            completedProposals: 2,
            totalProposals: 2,
            completedChoices: [(1, 0), (2, 1)]
        )
        let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
            VotingCoordFlow()
        } withDependencies: {
            self.sessionDependencies(&$0, recorder: recorder)
            $0.votingCrypto.sessionPlan = { _ in
                let call = recorder.recordAndCount("sessionPlan")
                return try self.plan(
                    needsBundleSetup: call == 1,
                    openProposals: [1, 2],
                    delegationBundlesNeedingWork: [0]
                )
            }
            $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
            $0.votingCrypto.precomputeDelegationProof = { _, bundleIndex in
                recorder.record("precompute:\(bundleIndex)")
                return AsyncThrowingStream { continuation in
                    continuation.yield(VotingDelegationProofEvent.finished(VotingDelegationProofStatus.generated))
                    continuation.finish()
                }
            }
            $0.votingCrypto.setBallotIntents = { _, _ in
                try self.plan(allDecided: true, delegationBundlesNeedingWork: [0])
            }
            $0.votingCrypto.runRound = { _, signer, _ in
                recorder.record(
                    signer == VotingDelegationSigner.software(seed: Self.walletSeed)
                        ? "runRound.software"
                        : "runRound.otherSigner"
                )
                return AsyncThrowingStream { continuation in
                    continuation.yield(VotingRoundRunEvent.finished(report))
                    continuation.finish()
                }
            }
        }

        store.send(.startActiveRoundPipeline(roundId: activeRoundId))
        await waitForStore { store.state.roundCache[self.activeRoundId]?.precomputeStatus[0] == .generated }

        store.send(.submitAllDraftsTapped(roundId: activeRoundId))
        await waitForStore {
            store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2)
        }

        #expect(recorder.events().filter { $0.hasPrefix("precompute:") } == ["precompute:0"])
        #expect(recorder.events().filter { $0.hasPrefix("runRound") } == ["runRound.software"])
        #expect(store.state.roundCache[self.activeRoundId]?.votes == [1: .option(0), 2: .option(1)])
        #expect(store.state.roundCache[self.activeRoundId]?.draftVotes.isEmpty == true)
    }

    /// A ballot the voter left partly blank is still a complete ballot to the
    /// crate: the skipped proposals are recorded as decisions, not omitted, or
    /// the round would never plan a cast.
    @MainActor
    @Test func confirmWritesBallotIntentsIncludingSkips() async throws {
        let recorder = EventRecorder()
        let intents = LockIsolated<[VotingBallotIntent]>([])
        let report = try runReport(kind: "no_work_left", completedProposals: 1, totalProposals: 2)
        // Proposal 1 carries options 0 and 1, so choice 2 is the synthetic
        // Abstain the ballot UI offers rather than a real option.
        let store = Store(initialState: sessionFlowState(drafts: [1: .option(2), 2: .option(1)])) {
            VotingCoordFlow()
        } withDependencies: {
            self.sessionDependencies(&$0, recorder: recorder)
            $0.votingCrypto.sessionPlan = { _ in
                let call = recorder.recordAndCount("sessionPlan")
                return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
            }
            $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
            $0.votingCrypto.setBallotIntents = { _, recorded in
                intents.withValue { $0 = recorded }
                return try self.plan(allDecided: true)
            }
            $0.votingCrypto.runRound = { _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(VotingRoundRunEvent.finished(report))
                    continuation.finish()
                }
            }
        }

        store.send(.startActiveRoundPipeline(roundId: activeRoundId))
        await waitForStore { self.isProposalListTop(store.state) }

        store.send(.submitAllDraftsTapped(roundId: activeRoundId))
        await waitForStore { intents.value.count == 2 }

        #expect(
            intents.value.sorted { $0.proposalId < $1.proposalId } == [
                VotingBallotIntent(proposalId: 1, decision: VotingBallotDecision.skipped),
                VotingBallotIntent(proposalId: 2, decision: VotingBallotDecision.choice(1))
            ]
        )
    }

    /// A submission the chain refused is terminal: the voter is told what the
    /// chain said, with the ballot counts, and not offered a silent success.
    @MainActor
    @Test func runReportChainTerminalShowsFailure() async throws {
        let recorder = EventRecorder()
        let report = try runReport(
            kind: "chain_terminal",
            completedProposals: 0,
            totalProposals: 2,
            chainOutcomeKind: "rejected",
            diagnostic: "consensus rejected the transaction"
        )
        let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
            VotingCoordFlow()
        } withDependencies: {
            self.sessionDependencies(&$0, recorder: recorder)
            $0.votingCrypto.sessionPlan = { _ in
                let call = recorder.recordAndCount("sessionPlan")
                return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
            }
            $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
            $0.votingCrypto.setBallotIntents = { _, _ in try self.plan(allDecided: true) }
            $0.votingCrypto.runRound = { _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(VotingRoundRunEvent.finished(report))
                    continuation.finish()
                }
            }
        }

        store.send(.startActiveRoundPipeline(roundId: activeRoundId))
        await waitForStore { self.isProposalListTop(store.state) }

        store.send(.submitAllDraftsTapped(roundId: activeRoundId))
        await waitForStore { store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus.isFailureState == true }

        guard
            case let .submissionFailed(error, submittedCount, totalCount) =
                tryUnwrap(store.state.roundCache[activeRoundId]).batchSubmissionStatus
        else {
            Issue.record("expected a submission failure")
            return
        }
        #expect(error.contains("rejected"))
        #expect(submittedCount == 0)
        #expect(totalCount == 2)
    }

    /// A session that has been replaced has a new epoch, and the events still
    /// arriving from the old one describe a round state that no longer exists —
    /// so they are dropped rather than written back over newer state.
    @Test func staleEpochEventsAreIgnored() throws {
        var session = RoundSession(roundId: activeRoundId)
        session.sessionEpoch = 5
        session.bundleCount = 1
        var state = VotingCoordFlow.State()
        state.roundCache[activeRoundId] = session
        let before = state.roundCache
        let report = try runReport(kind: "no_work_left", completedProposals: 2, totalProposals: 2)

        _ = VotingCoordFlow().reduceRoundRunEvent(
            &state,
            roundId: activeRoundId,
            epoch: 4,
            event: VotingRoundRunEvent.finished(report)
        )

        #expect(state.roundCache == before)
    }

    /// A run that exhausts its own pass budget is retried, but not forever: the
    /// fourth exhausted run is a failure the voter is told about instead of a
    /// loop they cannot see.
    @MainActor
    @Test func retryLaterReRunsAtMostThreeTimes() async throws {
        let recorder = EventRecorder()
        let report = try runReport(kind: "pass_budget_exhausted", completedProposals: 0, totalProposals: 2)
        let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
            VotingCoordFlow()
        } withDependencies: {
            self.sessionDependencies(&$0, recorder: recorder)
            $0.votingCrypto.sessionPlan = { _ in
                let call = recorder.recordAndCount("sessionPlan")
                return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
            }
            $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
            $0.votingCrypto.setBallotIntents = { _, _ in try self.plan(allDecided: true) }
            $0.votingCrypto.runRound = { _, _, _ in
                recorder.record("runRound")
                return AsyncThrowingStream { continuation in
                    continuation.yield(VotingRoundRunEvent.finished(report))
                    continuation.finish()
                }
            }
        }

        store.send(.startActiveRoundPipeline(roundId: activeRoundId))
        await waitForStore { self.isProposalListTop(store.state) }

        store.send(.submitAllDraftsTapped(roundId: activeRoundId))
        await waitForStore { store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus.isFailureState == true }

        #expect(recorder.events().filter { $0 == "runRound" }.count == 4)
        #expect(store.state.roundCache[self.activeRoundId]?.runRetryCount == 3)
    }

    // MARK: - Round session fixtures

    private static let walletSeed = [UInt8](repeating: 0x07, count: 32)

    /// The state an active round is entered from: one active round, a resolved
    /// service config, a software wallet account, and the polls-list spinner the
    /// entry is expected to clear.
    private func sessionFlowState(drafts: [UInt32: VoteChoice] = [:]) -> VotingCoordFlow.State {
        var session = RoundSession(roundId: activeRoundId)
        session.draftVotes = drafts
        var state = VotingCoordFlow.State()
        state.roundCache[activeRoundId] = session
        state.allRounds = [RoundListItem(roundNumber: 1, session: votingSession(proposalCount: 2))]
        state.serviceConfig = Self.makeServiceConfig(
            voteServers: [VotingServiceConfig.ServiceEndpoint(url: "https://vote.example.com", label: "vote")]
        )
        state.checkingEligibilityRoundId = activeRoundId
        state.$selectedWalletAccount.withLock { $0 = zashiWalletAccount() }
        state.$swapAPIAccess.withLock { $0 = .direct }
        return state
    }

    /// Everything the round-session path touches outside `votingCrypto`'s
    /// session calls, which each test stubs for itself.
    private func sessionDependencies(_ dependencies: inout DependencyValues, recorder: EventRecorder) {
        dependencies.sdkSynchronizer = .mocked(
            latestState: {
                var latestState = SynchronizerState.zero
                latestState.fullyScannedHeight = 1_000
                return latestState
            }
        )
        dependencies.sdkSynchronizer.getTreeState = { _ in Data([0x01]) }
        dependencies.databaseFiles.dataDbURLFor = { _ in URL(fileURLWithPath: "/tmp/voting-tests-data.db") }
        dependencies.mnemonic.toSeed = { _ in Self.walletSeed }
        dependencies.walletStorage.exportWallet = { StoredWallet.placeholder }
        dependencies.walletStorage.exportVotingHotkey = { _ in
            StoredVotingHotkey(storedSecret: VotingHotkeySecret(Data(repeating: 0x11, count: 32)), version: 1)
        }
        dependencies.localAuthentication.authenticate = { true }
        dependencies.backgroundTask = .noOp
        dependencies.votingAPI.startHealthProbeSweep = { }
        dependencies.votingMetadata = votingMetadataClient(VotingMetadataBox())
        dependencies.continuousClock = ImmediateClock()
        dependencies.votingCrypto.openRoundSession = { _, _, _, _ in recorder.record("openRoundSession") }
        dependencies.votingCrypto.closeRoundSession = { _ in }
        dependencies.votingCrypto.cancelRoundSession = { _ in }
        dependencies.votingCrypto.eligibility = { _ in try self.eligibilityReport() }
    }

    private func isProposalListTop(_ state: VotingCoordFlow.State) -> Bool {
        guard case .proposalList = state.path.last else { return false }
        return true
    }

    /// The crate's own wire shape for a plan, decoded rather than constructed:
    /// the SDK's views are `Decodable` only, and going through JSON keeps these
    /// tests honest about what a session actually answers with.
    private func plan(
        needsBundleSetup: Bool = false,
        openProposals: [UInt32] = [],
        allDecided: Bool = false,
        delegationBundlesNeedingWork: [UInt32] = [],
        completedChoices: [(UInt32, UInt32?)]? = nil
    ) throws -> VotingRoundPlan {
        let payload = planPayload(
            needsBundleSetup: needsBundleSetup,
            openProposals: openProposals,
            allDecided: allDecided,
            delegationBundlesNeedingWork: delegationBundlesNeedingWork,
            completedChoices: completedChoices
        )
        return try JSONDecoder().decode(VotingRoundPlan.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func planPayload(
        needsBundleSetup: Bool = false,
        openProposals: [UInt32] = [],
        allDecided: Bool = false,
        delegationBundlesNeedingWork: [UInt32] = [],
        completedChoices: [(UInt32, UInt32?)]? = nil
    ) -> [String: Any] {
        let noIntents: [Int] = []
        var payload: [String: Any] = [
            "round_id": activeRoundId,
            "pending_recovery": false,
            "blocking_recovery": false,
            "blocking_share_work": false,
            "has_unconfirmed_shares": false,
            "hotkey_bound": true,
            "completed_for_display": completedChoices != nil,
            "needs_draft_setup": false,
            "needs_bundle_setup": needsBundleSetup,
            "needs_delegation_signing": false,
            "has_in_flight_delegation": false,
            "delegation_bundles_needing_work": delegationBundlesNeedingWork.map { Int($0) },
            "delegation_bundles_needing_signing": noIntents,
            "needs_vote_polling": false,
            "has_remaining_vote_or_share_work": !allDecided,
            "has_recoverable_vote_or_share_work": !allDecided,
            "primary_action": needsBundleSetup ? "delegate" : "vote",
            "delegation_statuses": [["bundle_index": 0, "phase": "prepared", "terminal": false]],
            "open_proposals": openProposals.map { Int($0) },
            "unrostered_intents": noIntents,
            "immediate_share_confirmed": false,
            "all_decided": allDecided
        ]
        if let completedChoices {
            payload["completed_vote_display"] = [
                "choices": completedChoices.map { choice -> [String: Any] in
                    ["proposal_id": Int(choice.0), "choice": choice.1.map { Int($0) } as Any]
                }
            ]
        }
        return payload
    }

    private func bundleLayout(bundleCount: UInt32, eligibleWeight: UInt64) throws -> VotingBundleLayout {
        let payload: [String: Any] = [
            "bundle_count": Int(bundleCount),
            "eligible_weight": Int(eligibleWeight),
            "dropped_count": 0,
            "privacy_trim_dropped_bundles": 0,
            "privacy_trim_dropped_notes": 0
        ]
        return try JSONDecoder().decode(VotingBundleLayout.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func eligibilityReport(eligibleWeight: UInt64 = 50_000_000) throws -> VotingEligibilityReport {
        let payload: [String: Any] = [
            "distinct_note_count": 1,
            "eligible_weight": Int(eligibleWeight),
            "is_eligible": eligibleWeight > 0,
            "privacy_trim_dropped_value_zatoshi": 0
        ]
        return try JSONDecoder().decode(VotingEligibilityReport.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func runReport(
        kind: String,
        completedProposals: UInt32,
        totalProposals: UInt32,
        chainOutcomeKind: String? = nil,
        diagnostic: String? = nil,
        completedChoices: [(UInt32, UInt32?)]? = nil
    ) throws -> VotingRoundRunReport {
        var quiescence: [String: Any] = ["kind": kind]
        if let chainOutcomeKind {
            var outcome: [String: Any] = ["kind": chainOutcomeKind]
            if let diagnostic {
                outcome["diagnostic"] = ["message": diagnostic]
            }
            quiescence["chain_outcome"] = outcome
        }
        var payload: [String: Any] = [
            "quiescence": quiescence,
            "tally": [
                "completed_proposals": Int(completedProposals),
                "total_proposals": Int(totalProposals),
                "remaining_obligations": Int(totalProposals - completedProposals)
            ]
        ]
        if let completedChoices {
            payload["plan"] = planPayload(allDecided: true, completedChoices: completedChoices)
        }
        return try JSONDecoder().decode(VotingRoundRunReport.self, from: JSONSerialization.data(withJSONObject: payload))
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
