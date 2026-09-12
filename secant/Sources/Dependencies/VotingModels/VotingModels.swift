import Foundation
@preconcurrency import ZcashLightClientKit

// MARK: - Ballot Constants

/// Ballot divisor in zatoshi (0.125 ZEC). Must match `zcash_voting::governance::BALLOT_DIVISOR`.
/// One ballot = this many zatoshi. Used for quantizing note bundle weights and tally display.
let ballotDivisor: UInt64 = 12_500_000

/// Quantizes a zatoshi amount down to the nearest ballot boundary.
func quantizeWeight(_ zatoshi: UInt64) -> UInt64 {
    (zatoshi / ballotDivisor) * ballotDivisor
}

// MARK: - Last-Moment Buffer Constants

/// Fraction of round duration used as the last-moment buffer (40%).
private let lastMomentBufferFraction: Double = 0.4

/// Maximum last-moment buffer duration in seconds (6 hours).
private let lastMomentBufferMaxSeconds: TimeInterval = 21_600

// MARK: - Session & Round

/// Full on-chain representation from VoteRound proto (zvote/v1/types.proto).
/// vote_round_id is a canonical 32-byte Pallas Fp value derived on-chain from
/// session setup fields via Poseidon hash.
struct VotingSession: Equatable, Sendable {
    let voteRoundId: Data
    let snapshotHeight: UInt64
    let snapshotBlockhash: Data
    let proposalsHash: Data
    let voteEndTime: Date
    let ceremonyStart: Date
    let eaPK: Data
    let vkZkp1: Data
    let vkZkp2: Data
    let vkZkp3: Data
    let ncRoot: Data
    let nullifierIMTRoot: Data
    let creator: String
    let description: String
    let discussionURL: URL?
    let proposals: [VotingProposal]
    let status: SessionStatus
    let createdAtHeight: UInt64
    let title: String

    /// The last-moment buffer defines a window before vote end during which votes
    /// are treated as "last-moment" — submitted immediately with `submit_at=0`
    /// and using single-share mode. Computed as 40% of the total round duration
    /// (ceremony start -> vote end), capped at 6 hours.
    var lastMomentBuffer: TimeInterval? {
        // Total voting window: from when the ceremony started to when voting ends.
        let duration = voteEndTime.timeIntervalSince(ceremonyStart)
        guard duration > 0 else {
            return nil
        }
        // 40% of round duration, but never more than 6 hours.
        return min(duration * lastMomentBufferFraction, lastMomentBufferMaxSeconds)
    }

    /// Returns `true` when the current time falls within the last-moment buffer before vote end.
    /// Returns `false` if round times are invalid (buffer cannot be computed).
    var isLastMoment: Bool {
        guard let buffer = lastMomentBuffer else { return false }
        return Date().timeIntervalSince1970 >= voteEndTime.timeIntervalSince1970 - buffer
    }

    init(
        voteRoundId: Data,
        snapshotHeight: UInt64,
        snapshotBlockhash: Data,
        proposalsHash: Data,
        voteEndTime: Date,
        ceremonyStart: Date = Date(timeIntervalSince1970: 0),
        eaPK: Data,
        vkZkp1: Data,
        vkZkp2: Data,
        vkZkp3: Data,
        ncRoot: Data,
        nullifierIMTRoot: Data,
        creator: String,
        description: String = "",
        discussionURL: URL? = nil,
        proposals: [VotingProposal],
        status: SessionStatus,
        createdAtHeight: UInt64 = 0,
        title: String = ""
    ) {
        self.voteRoundId = voteRoundId
        self.snapshotHeight = snapshotHeight
        self.snapshotBlockhash = snapshotBlockhash
        self.proposalsHash = proposalsHash
        self.voteEndTime = voteEndTime
        self.ceremonyStart = ceremonyStart
        self.eaPK = eaPK
        self.vkZkp1 = vkZkp1
        self.vkZkp2 = vkZkp2
        self.vkZkp3 = vkZkp3
        self.ncRoot = ncRoot
        self.nullifierIMTRoot = nullifierIMTRoot
        self.creator = creator
        self.description = description
        self.discussionURL = discussionURL
        self.proposals = proposals
        self.status = status
        self.createdAtHeight = createdAtHeight
        self.title = title
    }
}

/// Maps to proto SessionStatus (zvote/v1/types.proto).
enum SessionStatus: UInt32, Equatable, Sendable {
    case unspecified = 0
    case active = 1
    case tallying = 2
    case finalized = 3
}

// MARK: - Round State (from Rust storage)

enum RoundPhaseInfo: Equatable, Sendable {
    case initialized
    case hotkeyGenerated
    case delegationConstructed
    case delegationProved
    case voteReady
}

struct RoundStateInfo: Equatable, Sendable {
    let roundId: String
    let phase: RoundPhaseInfo
    let snapshotHeight: UInt64
    let hotkeyAddress: String?
    let delegatedWeight: UInt64?
    let proofGenerated: Bool

    init(
        roundId: String,
        phase: RoundPhaseInfo,
        snapshotHeight: UInt64,
        hotkeyAddress: String?,
        delegatedWeight: UInt64?,
        proofGenerated: Bool
    ) {
        self.roundId = roundId
        self.phase = phase
        self.snapshotHeight = snapshotHeight
        self.hotkeyAddress = hotkeyAddress
        self.delegatedWeight = delegatedWeight
        self.proofGenerated = proofGenerated
    }
}

struct RoundSummaryInfo: Equatable, Sendable {
    let roundId: String
    let phase: RoundPhaseInfo
    let snapshotHeight: UInt64
    let createdAt: UInt64

    init(roundId: String, phase: RoundPhaseInfo, snapshotHeight: UInt64, createdAt: UInt64) {
        self.roundId = roundId
        self.phase = phase
        self.snapshotHeight = snapshotHeight
        self.createdAt = createdAt
    }
}

// MARK: - Vote Record (from Rust votes table)

struct VoteRecord: Equatable, Sendable {
    let proposalId: UInt32
    let bundleIndex: UInt32
    let choice: VoteChoice
    let submitted: Bool

    init(proposalId: UInt32, bundleIndex: UInt32, choice: VoteChoice, submitted: Bool) {
        self.proposalId = proposalId
        self.bundleIndex = bundleIndex
        self.choice = choice
        self.submitted = submitted
    }
}

/// Combined DB state published via stateStream. Drives all UI state.
struct VotingDbState: Equatable, Sendable {
    let roundState: RoundStateInfo
    let votes: [VoteRecord]
    let bundleCount: UInt32

    init(roundState: RoundStateInfo, votes: [VoteRecord], bundleCount: UInt32 = 0) {
        self.roundState = roundState
        self.votes = votes
        self.bundleCount = bundleCount
    }

    /// Convenience: build the votes dictionary the UI needs.
    /// With multi-bundle, multiple VoteRecords may exist per proposal (one per bundle).
    /// A proposal is only considered "voted" when ALL of its bundle votes are submitted
    /// AND the expected number of bundle records exist (guards against crash before a
    /// later bundle's buildVoteCommitment creates its VoteRecord).
    var votesByProposal: [UInt32: VoteChoice] {
        var byProposal: [UInt32: [VoteRecord]] = [:]
        for vote in votes {
            byProposal[vote.proposalId, default: []].append(vote)
        }
        var result: [UInt32: VoteChoice] = [:]
        for (proposalId, records) in byProposal {
            let allSubmitted = records.allSatisfy(\.submitted)
            let hasAllBundles = bundleCount == 0 || UInt32(records.count) >= bundleCount
            if allSubmitted && hasAllBundles {
                result[proposalId] = records.first?.choice
            }
        }
        return result
    }

    static let initial = VotingDbState(
        roundState: RoundStateInfo(
            roundId: "",
            phase: .initialized,
            snapshotHeight: 0,
            hotkeyAddress: nil,
            delegatedWeight: nil,
            proofGenerated: false
        ),
        votes: [],
        bundleCount: 0
    )
}

// MARK: - Hotkey

struct VotingHotkey: Equatable, Sendable {
    /// The material to persist via `WalletStorage.importVotingHotkey(_:accountId:)`. Treat it
    /// as key material, not as an identifier.
    let storedSecret: Data
    /// Raw Orchard address bytes for the hotkey, derived from `storedSecret`.
    let rawOrchardAddress: Data
    /// Address index the hotkey's Orchard address was derived at.
    let addressIndex: UInt32

    init(storedSecret: Data, rawOrchardAddress: Data, addressIndex: UInt32) {
        self.storedSecret = storedSecret
        self.rawOrchardAddress = rawOrchardAddress
        self.addressIndex = addressIndex
    }
}

// MARK: - Tally

/// Maps to QueryProposalTallyResponse (zvote/v1/query.proto).
/// Chain returns map<uint32, uint64> (vote_decision → accumulated amount).
struct TallyResult: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let decision: UInt32
        let amount: UInt64

        init(decision: UInt32, amount: UInt64) {
            self.decision = decision
            self.amount = amount
        }
    }

    let entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
    }
}

// MARK: - Notes

struct NoteInfo: Equatable, Sendable {
    let commitment: Data
    let nullifier: Data
    let value: UInt64
    let position: UInt64
    let diversifier: Data
    let rho: Data
    let rseed: Data
    let scope: UInt32
    let ufvkStr: String

    init(
        commitment: Data,
        nullifier: Data,
        value: UInt64,
        position: UInt64,
        diversifier: Data,
        rho: Data,
        rseed: Data,
        scope: UInt32,
        ufvkStr: String
    ) {
        self.commitment = commitment
        self.nullifier = nullifier
        self.value = value
        self.position = position
        self.diversifier = diversifier
        self.rho = rho
        self.rseed = rseed
        self.scope = scope
        self.ufvkStr = ufvkStr
    }
}

// MARK: - Round session streams

/// One step of a standalone delegation-proof precompute.
///
/// The SDK reports progress through a closure and answers with a status when
/// the proof is done; the app wants both on one channel, so the client wraps
/// them into a stream of these.
enum VotingDelegationProofEvent: Equatable, Sendable {
    case progress(VotingDelegationProgress)
    case finished(VotingDelegationProofStatus)
}

/// One step of a round run: a driver event, or the report the run ended with.
///
/// The report is authoritative — events are a best-effort narration the SDK
/// may drop under load — so a consumer that only reads `.finished` still sees
/// everything that happened.
enum VotingRoundRunEvent: Equatable, Sendable {
    case event(VotingRoundDriveEvent)
    case finished(VotingRoundRunReport)
}

/// One step of a share-tracking run, on the same terms as ``VotingRoundRunEvent``.
enum VotingShareTrackingRunEvent: Equatable, Sendable {
    case event(VotingShareTrackingEvent)
    case finished(VotingShareTrackingRunReport)
}
