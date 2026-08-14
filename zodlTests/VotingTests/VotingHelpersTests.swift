#if VOTING_ENABLED
import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal

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
    var records: [String: PersistedVotingRecord] = [:]
}
#endif
