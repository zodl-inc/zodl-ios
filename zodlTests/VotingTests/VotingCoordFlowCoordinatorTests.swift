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
    @Test func duplicateKeystoneScanReducerRejectsWithoutExtractingSignature() async {
        let duplicateSighash = Data(repeating: 0x02, count: 32)
        let expectedMessage = String(localizable: .coinVoteDelegationSigningDuplicateSignature("1", "2"))
        let recorder = EventRecorder()
        let store = Store(
            initialState: scanState(
                pendingSighash: Data(repeating: 0x05, count: 32),
                existingSignatures: [
                    signature(byte: 1, bundleIndex: 0, sighash: duplicateSighash)
                ]
            )
        ) {
            VotingCoordFlow()
        } withDependencies: {
            $0.votingCrypto.extractPcztSighash = { _ in duplicateSighash }
            $0.votingCrypto.extractSpendAuthSignatureFromSignedPczt = { _, _ in
                recorder.record("spend-auth")
                throw TestError.unexpectedSpendAuthExtraction
            }
        }

        store.send(.keystoneScan(.presented(.foundVotingDelegationPCZT(Data([0x0A])))))
        await waitForStore {
            store.state.keystoneSignatureRejectionSheet?.message == expectedMessage
        }

        let session = tryUnwrap(store.state.roundCache[roundId])
        #expect(store.state.keystoneScan == nil)
        #expect(store.state.keystoneSignatureRejectionSheet?.message == expectedMessage)
        #expect(session.keystoneSigningStatus == .awaitingSignature)
        #expect(session.currentKeystoneBundleIndex == 1)
        #expect(session.pendingVotingPczt != nil)
        #expect(session.batchSubmissionStatus == .idle)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.events().isEmpty)
    }

    @MainActor
    @Test func wrongKeystoneScanReducerRejectsWithoutExtractingSignature() async {
        let pendingSighash = Data(repeating: 0x05, count: 32)
        let scannedSighash = Data(repeating: 0x06, count: 32)
        let expectedMessage = String(localizable: .coinVoteDelegationSigningWrongSignature("2", "2"))
        let recorder = EventRecorder()
        let store = Store(initialState: scanState(pendingSighash: pendingSighash)) {
            VotingCoordFlow()
        } withDependencies: {
            $0.votingCrypto.extractPcztSighash = { _ in scannedSighash }
            $0.votingCrypto.extractSpendAuthSignatureFromSignedPczt = { _, _ in
                recorder.record("spend-auth")
                throw TestError.unexpectedSpendAuthExtraction
            }
        }

        store.send(.keystoneScan(.presented(.foundVotingDelegationPCZT(Data([0x0B])))))
        await waitForStore {
            store.state.keystoneSignatureRejectionSheet?.message == expectedMessage
        }

        let session = tryUnwrap(store.state.roundCache[roundId])
        #expect(store.state.keystoneScan == nil)
        #expect(store.state.keystoneSignatureRejectionSheet?.message == expectedMessage)
        #expect(session.keystoneSigningStatus == .awaitingSignature)
        #expect(session.currentKeystoneBundleIndex == 1)
        #expect(session.pendingVotingPczt != nil)
        #expect(session.batchSubmissionStatus == .idle)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.events().isEmpty)
    }

    @MainActor
    @Test func keystoneAuthorizationSkipsRecoveredBundleAndSubmitsOnlyMissingBundle() async {
        let recorder = EventRecorder()
        let sig = signature(byte: 2, bundleIndex: 1)
        let store = Store(initialState: authorizationState(signatures: [sig], completedBundles: [0])) {
            VotingCoordFlow()
        } withDependencies: {
            self.configureKeystoneAuthorizationDependencies(&$0, recorder: recorder)
        }

        store.send(.keystoneAllBundlesSigned(roundId: activeRoundId))
        await waitForStore {
            store.state.roundCache[self.activeRoundId]?.delegationProofStatus == .complete
        }

        #expect(recorder.events() == [
            "recover:0",
            "recover:1",
            "prove:1",
            "registration:1",
            "submit:1",
            "store-tx:1:bundle-1-tx",
            "fetch:bundle-1-tx",
            "van:1:43"
        ])
        let session = tryUnwrap(store.state.roundCache[activeRoundId])
        #expect(session.delegationProofStatus == .complete)
        #expect(session.completedKeystoneDelegationBundleIndices.isEmpty)
    }

    @MainActor
    @Test func keystoneAuthorizationRecoversPersistedBundleAndSubmitsOnlyMissingBundle() async {
        let recorder = EventRecorder()
        let sig = signature(byte: 2, bundleIndex: 1)
        let store = Store(initialState: authorizationState(signatures: [sig], completedBundles: [])) {
            VotingCoordFlow()
        } withDependencies: {
            self.configureKeystoneAuthorizationDependencies(
                &$0,
                recorder: recorder,
                cachedRecoveredBundles: [0]
            )
        }

        store.send(.keystoneAllBundlesSigned(roundId: activeRoundId))
        await waitForStore {
            store.state.roundCache[self.activeRoundId]?.delegationProofStatus == .complete
        }

        #expect(recorder.events() == [
            "recover:0",
            "fetch:cached-bundle-0-tx",
            "van:0:43",
            "recover:1",
            "prove:1",
            "registration:1",
            "submit:1",
            "store-tx:1:bundle-1-tx",
            "fetch:bundle-1-tx",
            "van:1:43"
        ])
        let session = tryUnwrap(store.state.roundCache[activeRoundId])
        #expect(session.delegationProofStatus == .complete)
        #expect(session.completedKeystoneDelegationBundleIndices.isEmpty)
    }

    @MainActor
    @Test func recoveredPersistedKeystoneBundleIsRetainedIfLaterBundleFails() async {
        let recorder = EventRecorder()
        let expectedError = TestError.proofFailed.localizedDescription
        let sig = signature(byte: 2, bundleIndex: 1)
        let store = Store(initialState: authorizationState(signatures: [sig], completedBundles: [])) {
            VotingCoordFlow()
        } withDependencies: {
            self.configureKeystoneAuthorizationDependencies(
                &$0,
                recorder: recorder,
                failingProofBundleIndex: 1,
                cachedRecoveredBundles: [0]
            )
        }

        store.send(.keystoneAllBundlesSigned(roundId: activeRoundId))
        await waitForStore {
            store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .authorizationFailed(error: expectedError)
        }

        #expect(recorder.events() == [
            "recover:0",
            "fetch:cached-bundle-0-tx",
            "van:0:43",
            "recover:1",
            "prove:1"
        ])
        let session = tryUnwrap(store.state.roundCache[activeRoundId])
        #expect(session.completedKeystoneDelegationBundleIndices == Set([0]))
        #expect(session.currentKeystoneBundleIndex == 1)
        #expect(session.batchSubmissionStatus == .authorizationFailed(error: expectedError))
    }

    @MainActor
    @Test func successfulKeystoneBundleIsRetainedIfLaterBundleFails() async {
        let recorder = EventRecorder()
        let expectedError = TestError.proofFailed.localizedDescription
        let store = Store(
            initialState: authorizationState(
                signatures: [
                    signature(byte: 1, bundleIndex: 0),
                    signature(byte: 2, bundleIndex: 1)
                ],
                completedBundles: []
            )
        ) {
            VotingCoordFlow()
        } withDependencies: {
            self.configureKeystoneAuthorizationDependencies(
                &$0,
                recorder: recorder,
                failingProofBundleIndex: 1
            )
        }

        store.send(.keystoneAllBundlesSigned(roundId: activeRoundId))
        await waitForStore {
            store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .authorizationFailed(error: expectedError)
        }

        #expect(recorder.events() == [
            "recover:0",
            "recover:1",
            "prove:0",
            "registration:0",
            "submit:0",
            "store-tx:0:bundle-0-tx",
            "fetch:bundle-0-tx",
            "van:0:42",
            "prove:1"
        ])
        let session = tryUnwrap(store.state.roundCache[activeRoundId])
        #expect(session.completedKeystoneDelegationBundleIndices == Set([0]))
        #expect(session.keystoneBundleSignatures.isEmpty)
        #expect(session.currentKeystoneBundleIndex == 1)
        #expect(session.batchSubmissionStatus == .authorizationFailed(error: expectedError))
    }

    @MainActor
    @Test func retryBatchSubmissionResumesKeystoneAtFirstIncompleteBundle() async {
        let recorder = EventRecorder()
        var state = authorizationState(signatures: [], completedBundles: [0])
        state.roundCache[activeRoundId]?.draftVotes = [1: .option(0)]
        state.roundCache[activeRoundId]?.delegationProofStatus = .failed("failed")
        state.roundCache[activeRoundId]?.isDelegationProofInFlight = false
        state.roundCache[activeRoundId]?.keystoneSigningStatus = .idle
        state.roundCache[activeRoundId]?.batchSubmissionStatus = .authorizationFailed(error: "failed")
        let store = Store(initialState: state) {
            VotingCoordFlow()
        } withDependencies: {
            $0.backgroundTask = .noOp
            $0.mnemonic = .noOp
            $0.sdkSynchronizer = .noOp
            $0.walletStorage = .noOp
            $0.votingCrypto.extractOrchardFvkFromUfvk = { _, _ in Data([0x01]) }
            $0.votingCrypto.buildVotingPczt = { _, bundleIndex, _, _, _, _, _, _, _, _ in
                recorder.record("pczt:\(bundleIndex)")
                return Self.makeVotingPcztResult(pcztSighash: Data(repeating: UInt8(bundleIndex + 5), count: 32))
            }
        }

        store.send(.retryBatchSubmission(roundId: activeRoundId))
        await waitForStore {
            store.state.roundCache[self.activeRoundId]?.keystoneSigningStatus == .awaitingSignature
        }

        #expect(recorder.events() == ["pczt:1"])
        let session = tryUnwrap(store.state.roundCache[activeRoundId])
        #expect(session.completedKeystoneDelegationBundleIndices == Set([0]))
        #expect(session.currentKeystoneBundleIndex == 1)
        #expect(session.pendingVotingPczt != nil)
        #expect(session.batchSubmissionStatus == .authorizing)
    }

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

    @Test func delegationPipelineRecoversConfirmedCachedTxBeforeSkippingBundle() async throws {
        let recorder = RecoveryOrderRecorder()
        var votingCrypto = VotingCryptoClient()
        votingCrypto.getDelegationTxHash = { _, _ in .present("cached-tx") }
        votingCrypto.storeVanPosition = { _, bundleIndex, position in
            await recorder.record("van:\(bundleIndex):\(position)")
        }

        var votingAPI = VotingAPIClient()
        votingAPI.fetchTxConfirmation = { txHash in
            await recorder.record("fetch:\(txHash)")
            return Self.makeDelegationConfirmation(position: 42)
        }
        votingAPI.submitDelegation = { _ in
            await recorder.record("submit")
            return TxResult(txHash: "new-tx", code: 0)
        }

        try await VotingCoordFlow.runDelegationPipeline(
            roundId: "aabb",
            cachedNotes: [note(value: ballotDivisor, position: 0)],
            senderSeed: [],
            hotkeySeed: [],
            networkId: 1,
            accountIndex: 0,
            roundName: "Round",
            pirEndpoints: ["https://pir.example.com"],
            expectedSnapshotHeight: 1,
            votingCrypto: votingCrypto,
            votingAPI: votingAPI,
            send: Send<VotingCoordFlow.Action>(send: { _ in }),
            delegationConfirmationTimeout: 0,
            delegationConfirmationRetryDelay: .zero
        )

        let events = await recorder.events()
        #expect(events == ["fetch:cached-tx", "van:0:42"])
    }

    @Test func delegationPipelineDoesNotSkipCachedTxWithoutConfirmedVanPosition() async throws {
        let recorder = RecoveryOrderRecorder()
        var votingCrypto = VotingCryptoClient()
        votingCrypto.getDelegationTxHash = { _, _ in .present("cached-tx") }
        votingCrypto.buildVotingPczt = { _, _, _, _, _, _, _, _, _, _ in
            Self.makeVotingPcztResult()
        }
        votingCrypto.getDelegationSubmission = { _, _, _, _, _ in
            await recorder.record("registration")
            return Self.makeDelegationRegistration()
        }
        votingCrypto.storeDelegationTxHash = { _, _, txHash in
            await recorder.record("store-tx:\(txHash)")
        }
        votingCrypto.storeVanPosition = { _, bundleIndex, position in
            await recorder.record("van:\(bundleIndex):\(position)")
        }

        var votingAPI = VotingAPIClient()
        votingAPI.fetchTxConfirmation = { txHash in
            await recorder.record("fetch:\(txHash)")
            if txHash == "cached-tx" {
                return nil
            }
            return Self.makeDelegationConfirmation(position: 9)
        }
        votingAPI.submitDelegation = { _ in
            await recorder.record("submit")
            return TxResult(txHash: "new-tx", code: 0)
        }

        try await VotingCoordFlow.runDelegationPipeline(
            roundId: "aabb",
            cachedNotes: [note(value: ballotDivisor, position: 0)],
            senderSeed: [],
            hotkeySeed: [],
            networkId: 1,
            accountIndex: 0,
            roundName: "Round",
            pirEndpoints: ["https://pir.example.com"],
            expectedSnapshotHeight: 1,
            votingCrypto: votingCrypto,
            votingAPI: votingAPI,
            send: Send<VotingCoordFlow.Action>(send: { _ in }),
            delegationConfirmationTimeout: 0,
            delegationConfirmationRetryDelay: .zero
        )

        let events = await recorder.events()
        #expect(events == [
            "fetch:cached-tx",
            "registration",
            "submit",
            "store-tx:new-tx",
            "fetch:new-tx",
            "van:0:9"
        ])
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

    private func votingSession() -> VotingSession {
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
            status: .active,
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
        completedBundles: Set<UInt32>
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
            rounds: [:]
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

    private static func makeDelegationRegistration(
        rk: Data = Data(repeating: 0x01, count: 32),
        spendAuthSig: Data = Data(repeating: 0x02, count: 64),
        sighash: Data = Data(repeating: 0x08, count: 32)
    ) -> DelegationRegistration {
        DelegationRegistration(
            rk: rk,
            spendAuthSig: spendAuthSig,
            signedNoteNullifier: Data(repeating: 0x03, count: 32),
            cmxNew: Data(repeating: 0x04, count: 32),
            vanCmx: Data(repeating: 0x05, count: 32),
            govNullifiers: [Data(repeating: 0x06, count: 32)],
            proof: Data(repeating: 0x07, count: 32),
            voteRoundId: Data([0xAA, 0xBB]),
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
        timeoutNanoseconds: UInt64 = 2_000_000_000,
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

    private func configureKeystoneAuthorizationDependencies(
        _ dependencies: inout DependencyValues,
        recorder: EventRecorder,
        failingProofBundleIndex: UInt32? = nil,
        cachedRecoveredBundles: Set<UInt32> = []
    ) {
        dependencies.backgroundTask = .noOp
        dependencies.mnemonic = .noOp
        dependencies.walletStorage = .noOp
        dependencies.votingCrypto.getDelegationTxHash = { _, bundleIndex in
            recorder.record("recover:\(bundleIndex)")
            if cachedRecoveredBundles.contains(bundleIndex) {
                return .present("cached-bundle-\(bundleIndex)-tx")
            }
            return .notFound
        }
        dependencies.votingCrypto.buildAndProveDelegation = { _, bundleIndex, _, _, _, _, _, _, _ in
            recorder.record("prove:\(bundleIndex)")
            return AsyncThrowingStream { continuation in
                if bundleIndex == failingProofBundleIndex {
                    continuation.finish(throwing: TestError.proofFailed)
                } else {
                    continuation.yield(.progress(1))
                    continuation.finish()
                }
            }
        }
        dependencies.votingCrypto.getDelegationSubmissionWithKeystoneSig = { _, bundleIndex, sig, sighash in
            recorder.record("registration:\(bundleIndex)")
            return Self.makeDelegationRegistration(
                rk: Data(repeating: UInt8(bundleIndex + 3), count: 32),
                spendAuthSig: sig,
                sighash: sighash
            )
        }
        dependencies.votingCrypto.storeDelegationTxHash = { _, bundleIndex, txHash in
            recorder.record("store-tx:\(bundleIndex):\(txHash)")
        }
        dependencies.votingCrypto.storeVanPosition = { _, bundleIndex, position in
            recorder.record("van:\(bundleIndex):\(position)")
        }
        dependencies.votingAPI.submitDelegation = { registration in
            let bundleIndex = UInt32(max(Int(registration.spendAuthSig.first ?? 1) - 1, 0))
            recorder.record("submit:\(bundleIndex)")
            return TxResult(txHash: "bundle-\(bundleIndex)-tx", code: 0)
        }
        dependencies.votingAPI.fetchTxConfirmation = { txHash in
            recorder.record("fetch:\(txHash)")
            let position: UInt32 = txHash == "bundle-0-tx" ? 42 : 43
            return Self.makeDelegationConfirmation(position: position)
        }
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

    func events() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}

private enum TestError: LocalizedError {
    case unexpectedSpendAuthExtraction
    case proofFailed

    var errorDescription: String? {
        switch self {
        case .unexpectedSpendAuthExtraction:
            return "unexpected SpendAuth extraction"
        case .proofFailed:
            return "proof failed"
        }
    }
}
#endif
