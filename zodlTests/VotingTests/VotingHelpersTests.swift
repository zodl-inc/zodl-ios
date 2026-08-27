#if VOTING_ENABLED
import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite struct VotingHelpersTests {
    @Test func votingErrorMapperMapsPirProofRootMismatchToSnapshotMismatch() {
        let message = VotingErrorMapper.userFriendlyMessage(
            from: "Internal error: PIR proof root mismatch: expected aa, got bb"
        )

        #expect(message == String(localizable: .coinVoteStoreUserErrorPirSnapshotMismatch))
    }

    @Test func votingErrorMapperMapsPirProofVerificationFailureBeforeFetchFailure() {
        let message = VotingErrorMapper.userFriendlyMessage(
            from: "PIR parallel fetch failed: PIR proof verification failed: bad path"
        )

        #expect(message == String(localizable: .coinVoteStoreUserErrorPirInvalidProofData))
    }

    // 3.0-bump fingerprints (MOB-1678): the four new crate message shapes must land on
    // existing copy, not leak crate internals. Raw strings mirror pir-client 0.4.0-rc.7's
    // connect ensure, pir-types' validate_supported, and tree_sync.rs's VAN checks.

    @Test func votingErrorMapperMapsPolyLenMismatchToSnapshotMismatch() {
        let message = VotingErrorMapper.userFriendlyMessage(
            from: "Invalid input: PIR poly_len mismatch: expected 4096, server advertised 2048"
        )

        #expect(message == String(localizable: .coinVoteStoreUserErrorPirSnapshotMismatch))
    }

    @Test func votingErrorMapperMapsUnsupportedPirLayoutToConfigMessage() {
        let message = VotingErrorMapper.userFriendlyMessage(
            from: "unsupported PIR layout poly_len 1024; expected 2048 or 4096"
        )

        #expect(message == String(localizable: .coinVoteStoreUserErrorPirEndpointsMissing))
    }

    @Test func votingErrorMapperMapsVanLeafMismatchToRetryableOutOfSync() {
        let message = VotingErrorMapper.userFriendlyMessage(
            from: "Invalid input: confirmed delegation bundle 0 does not match its synced vote-tree leaf"
        )

        #expect(message == String(localizable: .coinVoteStoreUserErrorInvalidAnchorHeight))
    }

    @Test func votingErrorMapperMapsVanAbsentFromTreeToNotYetConfirmed() {
        let message = VotingErrorMapper.userFriendlyMessage(
            from: "Invalid input: confirmed delegation bundle 1 is absent from the synced vote tree"
        )

        #expect(message == String(localizable: .coinVoteStoreUserErrorCommitmentTreeNotGrown))
    }

    @Test func votingErrorMapperMapsTypedRecoveryErrors() {
        #expect(VotingErrorMapper.userFriendlyMessage(
            from: VotingFlowError.conflictingVoteSubmissionIntent(proposalId: 1)
        ) == String(localizable: .coinVoteStoreUserErrorConflictingSelection))
        #expect(VotingErrorMapper.userFriendlyMessage(
            from: VotingFlowError.omittedCommittedProposal(proposalId: 1)
        ) == String(localizable: .coinVoteStoreUserErrorOmittedCommittedProposal))
        #expect(VotingErrorMapper.userFriendlyMessage(
            from: VotingFlowError.recoveredVoteCommitmentMismatch(proposalId: 1, bundleIndex: 0)
        ) == String(localizable: .coinVoteStoreUserErrorRecoveredVoteMismatch))
        #expect(VotingErrorMapper.userFriendlyMessage(
            from: VotingFlowError.recoveredVoteVerificationUnavailable(proposalId: 1, bundleIndex: 0)
        ) == String(localizable: .coinVoteStoreUserErrorRecoveredVoteUnverified))
    }

    @Test func smartBundlesUsesRustOrderingAndPerBundleQuantization() {
        let notes = [
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

        let result = notes.smartBundles()

        let positions = result.bundles.map { $0.map(\.position) }
        #expect(positions == [
            [0, 1, 2, 3, 4],
            [5, 6, 7, 8, 9]
        ])
        #expect(result.bundles.map(Self.total) == [
            88_068_000,
            13_000_000
        ])
        let quantized = result.bundles.map { quantizeWeight(Self.total($0)) }
        #expect(quantized == [
            87_500_000,
            12_500_000
        ])
        #expect(result.eligibleWeight == 100_000_000)
        #expect(result.droppedCount == 0)
    }

    @Test func smartBundlesDropsTrailingDustBundle() {
        let notes = [
            note(value: 30_000_000, position: 0),
            note(value: 20_000_000, position: 1),
            note(value: 10_000_000, position: 2),
            note(value: 10_000_000, position: 3),
            note(value: 5_000_000, position: 4),
            note(value: 1_000_000, position: 5)
        ]

        let result = notes.smartBundles()

        let positions = result.bundles.map { $0.map(\.position) }
        #expect(positions == [[0, 1, 2, 3, 4]])
        #expect(result.eligibleWeight == 75_000_000)
        #expect(result.droppedCount == 1)
    }

    @Test func votingAuthorizationMemoUsesRawEightDecimalBundleTotal() {
        #expect(votingRawZecString(31_568_000) == "0.31568000")
        #expect(
            votingAuthorizationMemo(pollTitle: "Shielded Poll", rawWeight: 31_568_000)
                == "I am authorizing this hotkey managed by my wallet to vote on Shielded Poll with 0.31568000 ZEC."
        )
    }

    @Test func submittedVotesByProposalRequiresEveryExpectedBundle() {
        let records = [
            VoteRecord(proposalId: 1, bundleIndex: 0, choice: .option(0), submitted: true),
            VoteRecord(proposalId: 1, bundleIndex: 1, choice: .option(0), submitted: true),
            VoteRecord(proposalId: 2, bundleIndex: 0, choice: .option(1), submitted: true),
            VoteRecord(proposalId: 3, bundleIndex: 0, choice: .option(1), submitted: false),
            VoteRecord(proposalId: 3, bundleIndex: 1, choice: .option(1), submitted: true)
        ]

        #expect(submittedVotesByProposal(records, bundleCount: 2) == [1: .option(0)])
    }

    @Test func submittedVotesByProposalAllowsLegacyUnknownBundleCount() {
        let records = [
            VoteRecord(proposalId: 1, bundleIndex: 0, choice: .option(0), submitted: true),
            VoteRecord(proposalId: 2, bundleIndex: 0, choice: .option(1), submitted: false)
        ]

        #expect(submittedVotesByProposal(records, bundleCount: 0) == [1: .option(0)])
    }

    @Test func syntheticAbstainOnlyMatchesUiGeneratedChoice() {
        let proposal = VotingProposal(
            id: 1,
            title: "ZIP Poll",
            description: "",
            options: [
                VoteOption(index: 0, label: "Support"),
                VoteOption(index: 1, label: "Oppose")
            ]
        )
        let proposalWithNativeAbstain = VotingProposal(
            id: 2,
            title: "ZIP Poll",
            description: "",
            options: [
                VoteOption(index: 0, label: "Support"),
                VoteOption(index: 1, label: "Oppose"),
                VoteOption(index: 2, label: "Abstain")
            ]
        )

        #expect(Voting.isSyntheticAbstain(choice: .option(2), proposal: proposal))
        #expect(!Voting.isSyntheticAbstain(choice: .option(1), proposal: proposal))
        #expect(!Voting.isSyntheticAbstain(choice: .option(3), proposal: proposalWithNativeAbstain))
        #expect(!Voting.isSyntheticAbstain(choice: .option(2), proposal: nil))
    }

    @Test func loadCompletedVoteRecordClearsStaleRecordWhenDraftsRemain() {
        let roundId = "round-1"
        let metadata = VotingHelpersMetadataBox()
        metadata.records[roundId] = PersistedVotingRecord(
            votedAt: 1_700_000_000,
            votingWeight: ballotDivisor,
            proposalCount: 1,
            eligibleVotingWeight: nil,
            submittedBundleCount: nil,
            totalBundleCount: nil
        )
        metadata.drafts[roundId] = ["1": 0]

        withDependencies {
            $0.votingMetadata = votingMetadataClient(metadata)
        } operation: {
            #expect(Voting.loadCompletedVoteRecord(roundId: roundId, account: nil) == nil)
        }

        #expect(metadata.records[roundId] == nil)
        #expect(metadata.drafts[roundId] == ["1": 0])
    }

    @Test func voteRecordReportsSkippedKeystoneBundles() {
        let skippedRecord = Voting.VoteRecord(
            votedAt: Date(timeIntervalSince1970: 1_000),
            votingWeight: 25_000_000,
            proposalCount: 2,
            eligibleVotingWeight: 100_000_000,
            submittedBundleCount: 1,
            totalBundleCount: 4
        )
        let completeRecord = Voting.VoteRecord(
            votedAt: Date(timeIntervalSince1970: 1_000),
            votingWeight: 100_000_000,
            proposalCount: 2,
            eligibleVotingWeight: 100_000_000,
            submittedBundleCount: 4,
            totalBundleCount: 4
        )

        #expect(skippedRecord.skippedKeystoneBundleCount == 3)
        #expect(skippedRecord.hasSkippedKeystoneBundles)
        #expect(completeRecord.skippedKeystoneBundleCount == nil)
        #expect(!completeRecord.hasSkippedKeystoneBundles)
    }

    @Test func singleShareLockReusesOriginalMode() throws {
        let metadata = VotingHelpersMetadataBox()

        try withDependencies {
            $0.votingMetadata = votingMetadataClient(metadata)
        } operation: {
            let first = try Voting.lockSingleShareMode(
                proposedSingleShare: false,
                roundId: "round-1",
                account: nil
            )
            let retry = try Voting.lockSingleShareMode(
                proposedSingleShare: true,
                roundId: "round-1",
                account: nil
            )

            #expect(!first)
            #expect(!retry)
        }
    }

    @Test func voteSubmissionIntentLockAllowsOtherLockedProposalToBeOmitted() throws {
        let metadata = VotingHelpersMetadataBox()
        let firstIntent = Voting.VoteSubmissionIntent(choice: .option(1), numOptions: 3)
        let secondIntent = Voting.VoteSubmissionIntent(choice: .option(0), numOptions: 5)

        try withDependencies {
            $0.votingMetadata = votingMetadataClient(metadata)
        } operation: {
            try Voting.lockVoteSubmissionIntent(
                firstIntent,
                proposalId: 7,
                roundId: "round-1",
                account: nil
            )
            try Voting.lockVoteSubmissionIntent(
                secondIntent,
                proposalId: 8,
                roundId: "round-1",
                account: nil
            )

            #expect(Voting.loadSubmissionIntents(roundId: "round-1") == [
                7: firstIntent,
                8: secondIntent
            ])
        }
    }

    @Test func voteSubmissionLockRejectsChangedPendingChoice() throws {
        let metadata = VotingHelpersMetadataBox()

        try withDependencies {
            $0.votingMetadata = votingMetadataClient(metadata)
        } operation: {
            try Voting.lockVoteSubmissionIntent(
                Voting.VoteSubmissionIntent(choice: .option(1), numOptions: 3),
                proposalId: 7,
                roundId: "round-1",
                account: nil
            )

            #expect(throws: VotingFlowError.self) {
                try Voting.lockVoteSubmissionIntent(
                    Voting.VoteSubmissionIntent(choice: .option(2), numOptions: 3),
                    proposalId: 7,
                    roundId: "round-1",
                    account: nil
                )
            }
        }
    }

    @Test func legacyVotingMetadataDecodesWithEmptySubmissionLocks() throws {
        let data = Data(#"{"drafts":{"round-1":{"7":1}},"schemaVersion":1}"#.utf8)
        let metadata = try JSONDecoder().decode(VotingMetadata.self, from: data)

        #expect(metadata.drafts == ["round-1": ["7": 1]])
        #expect(metadata.submissionIntents.isEmpty)
        #expect(metadata.singleShareModes.isEmpty)
    }

    @Test func votingMetadataRoundTripsNonemptySubmissionLocks() throws {
        let metadata = VotingMetadata(
            submissionIntents: [
                "round-1": [
                    "7": PersistedVoteSubmissionIntent(choice: 1, numOptions: 3),
                    "8": PersistedVoteSubmissionIntent(choice: 0, numOptions: 5)
                ]
            ],
            singleShareModes: ["round-1": false]
        )

        let encoded = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(VotingMetadata.self, from: encoded)

        #expect(decoded == metadata)
    }

    @Test func voteSubmissionIntentLockRollsBackWhenMetadataStoreFails() {
        let roundId = "round-1"
        let metadata = VotingHelpersMetadataBox()
        let previousIntent = PersistedVoteSubmissionIntent(choice: 1, numOptions: 3)
        metadata.submissionIntents[roundId] = ["7": previousIntent]
        var client = votingMetadataClient(metadata)
        client.store = { _ in throw VotingMetadataTestError.storeFailed }

        withDependencies {
            $0.votingMetadata = client
        } operation: {
            #expect(throws: VotingMetadataTestError.self) {
                try Voting.lockVoteSubmissionIntent(
                    Voting.VoteSubmissionIntent(choice: .option(0), numOptions: 5),
                    proposalId: 8,
                    roundId: roundId,
                    account: account()
                )
            }
        }

        #expect(metadata.submissionIntents[roundId] == ["7": previousIntent])
    }

    @Test func singleShareLockRollsBackWhenMetadataStoreFails() {
        let roundId = "round-1"
        let metadata = VotingHelpersMetadataBox()
        var client = votingMetadataClient(metadata)
        client.store = { _ in throw VotingMetadataTestError.storeFailed }

        withDependencies {
            $0.votingMetadata = client
        } operation: {
            #expect(throws: VotingMetadataTestError.self) {
                _ = try Voting.lockSingleShareMode(
                    proposedSingleShare: true,
                    roundId: roundId,
                    account: account()
                )
            }
        }

        #expect(metadata.singleShareModes[roundId] == nil)
    }

    private static func total(_ notes: [NoteInfo]) -> UInt64 {
        notes.reduce(UInt64(0)) { $0 + $1.value }
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

    private func account() -> Account {
        Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: "Zodl",
            keySource: "zodl",
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        )
    }

    private func votingMetadataClient(
        _ box: VotingHelpersMetadataBox
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
        client.loadSubmissionIntents = { box.submissionIntents[$0] ?? [:] }
        client.setSubmissionIntents = { intents, roundId in
            box.submissionIntents[roundId] = intents
        }
        client.clearSubmissionIntents = { roundId in box.submissionIntents[roundId] = [:] }
        client.singleShareMode = { box.singleShareModes[$0] }
        client.setSingleShareMode = { singleShare, roundId in
            box.singleShareModes[roundId] = singleShare
        }
        client.clearSingleShareMode = { roundId in box.singleShareModes.removeValue(forKey: roundId) }
        client.record = { box.records[$0] }
        client.allRecords = { box.records }
        client.setRecord = { record, roundId in box.records[roundId] = record }
        client.clearRecord = { roundId in box.records.removeValue(forKey: roundId) }
        return client
    }
}

private final class VotingHelpersMetadataBox: @unchecked Sendable {
    var drafts: [String: [String: UInt32]] = [:]
    var submittedVotes: [String: [String: UInt32]] = [:]
    var submissionIntents: [String: [String: PersistedVoteSubmissionIntent]] = [:]
    var singleShareModes: [String: Bool] = [:]
    var records: [String: PersistedVotingRecord] = [:]
}

private enum VotingMetadataTestError: Error {
    case storeFailed
}
#endif
