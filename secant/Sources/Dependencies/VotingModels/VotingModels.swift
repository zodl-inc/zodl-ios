import Foundation

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

/// Lightweight subset of VotingSession passed to crypto operations.
struct VotingRoundParams: Equatable, Sendable {
    let voteRoundId: Data
    let snapshotHeight: UInt64
    let eaPK: Data
    let ncRoot: Data
    let nullifierIMTRoot: Data

    init(
        voteRoundId: Data,
        snapshotHeight: UInt64,
        eaPK: Data,
        ncRoot: Data,
        nullifierIMTRoot: Data
    ) {
        self.voteRoundId = voteRoundId
        self.snapshotHeight = snapshotHeight
        self.eaPK = eaPK
        self.ncRoot = ncRoot
        self.nullifierIMTRoot = nullifierIMTRoot
    }
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
    let secretKey: Data
    let publicKey: Data
    let address: String

    init(secretKey: Data, publicKey: Data, address: String) {
        self.secretKey = secretKey
        self.publicKey = publicKey
        self.address = address
    }
}

// MARK: - Voting PCZT

/// Result of building a voting PCZT for Keystone signing.
/// Contains the serialized PCZT bytes plus all metadata needed for ZKP #1 witness construction.
struct VotingPcztResult: Equatable, Sendable {
    /// Serialized PCZT bytes for UR-encoding and Keystone signing.
    let pcztBytes: Data
    /// Randomized verification key (32 bytes).
    let rk: Data // swiftlint:disable:this identifier_name
    /// Spend auth randomizer scalar (32 bytes).
    let alpha: Data
    /// Signed note nullifier (32 bytes). Public input to ZKP #1.
    let nfSigned: Data
    /// Output note commitment (32 bytes). Public input to ZKP #1.
    let cmxNew: Data
    /// Governance nullifiers, always padded to 5.
    let govNullifiers: [Data]
    /// 32-byte governance commitment (VAN).
    let van: Data
    /// 32-byte blinding factor used for VAN.
    let vanCommRand: Data
    /// Random nullifiers used for padded dummy notes.
    let dummyNullifiers: [Data]
    /// Constrained rho for the signed note (32 bytes).
    let rhoSigned: Data
    /// Extracted note commitments (cmx) for padded dummy notes.
    let paddedCmx: [Data]
    /// Signed note rseed (32 bytes).
    let rseedSigned: Data
    /// Output note rseed (32 bytes).
    let rseedOutput: Data
    /// Canonical delegation action payload for cosmos chain submission.
    let actionBytes: Data
    /// Index of the governance action within the PCZT's Orchard bundle.
    let actionIndex: UInt32

    init(
        pcztBytes: Data,
        rk: Data, // swiftlint:disable:this identifier_name
        alpha: Data,
        nfSigned: Data,
        cmxNew: Data,
        govNullifiers: [Data],
        van: Data,
        vanCommRand: Data,
        dummyNullifiers: [Data],
        rhoSigned: Data,
        paddedCmx: [Data],
        rseedSigned: Data,
        rseedOutput: Data,
        actionBytes: Data,
        actionIndex: UInt32
    ) {
        self.pcztBytes = pcztBytes
        self.rk = rk
        self.alpha = alpha
        self.nfSigned = nfSigned
        self.cmxNew = cmxNew
        self.govNullifiers = govNullifiers
        self.van = van
        self.vanCommRand = vanCommRand
        self.dummyNullifiers = dummyNullifiers
        self.rhoSigned = rhoSigned
        self.paddedCmx = paddedCmx
        self.rseedSigned = rseedSigned
        self.rseedOutput = rseedOutput
        self.actionBytes = actionBytes
        self.actionIndex = actionIndex
    }
}

// MARK: - Delegation

/// Intermediate client-side type: the built action before proof generation.
struct DelegationAction: Equatable, Sendable {
    let actionBytes: Data
    let rk: Data // swiftlint:disable:this identifier_name
    /// Governance nullifiers, always padded to 5.
    let govNullifiers: [Data]
    /// 32-byte governance commitment (VAN).
    let van: Data
    /// 32-byte blinding factor used for VAN.
    let vanCommRand: Data
    /// Random nullifiers used for padded dummy notes (needed for circuit witness).
    let dummyNullifiers: [Data]
    /// Constrained rho for the signed note (32 bytes). Spec §1.3.4.1.
    let rhoSigned: Data
    /// Extracted note commitments (cmx) for padded dummy notes.
    let paddedCmx: [Data]
    /// Signed note nullifier (32 bytes). Public input to ZKP #1.
    let nfSigned: Data
    /// Output note commitment (32 bytes). Public input to ZKP #1.
    let cmxNew: Data
    /// Spend auth randomizer scalar (32 bytes). Needed for Keystone signing.
    let alpha: Data
    /// Signed note rseed (32 bytes). Needed for witness reconstruction.
    let rseedSigned: Data
    /// Output note rseed (32 bytes). Needed for witness reconstruction.
    let rseedOutput: Data
    /// Spend authorization signature returned from Keystone over the delegation dummy action.
    let spendAuthSig: Data?

    init(
        actionBytes: Data,
        rk: Data, // swiftlint:disable:this identifier_name
        govNullifiers: [Data],
        van: Data,
        vanCommRand: Data,
        dummyNullifiers: [Data],
        rhoSigned: Data,
        paddedCmx: [Data],
        nfSigned: Data,
        cmxNew: Data,
        alpha: Data,
        rseedSigned: Data,
        rseedOutput: Data,
        spendAuthSig: Data? = nil
    ) {
        self.actionBytes = actionBytes
        self.rk = rk
        self.govNullifiers = govNullifiers
        self.van = van
        self.vanCommRand = vanCommRand
        self.dummyNullifiers = dummyNullifiers
        self.rhoSigned = rhoSigned
        self.paddedCmx = paddedCmx
        self.nfSigned = nfSigned
        self.cmxNew = cmxNew
        self.alpha = alpha
        self.rseedSigned = rseedSigned
        self.rseedOutput = rseedOutput
        self.spendAuthSig = spendAuthSig
    }
}

/// Maps to MsgDelegateVote (zvote/v1/tx.proto).
/// All fields needed for the on-chain delegation transaction.
struct DelegationRegistration: Equatable, Sendable {
    let rk: Data // swiftlint:disable:this identifier_name
    let spendAuthSig: Data
    let signedNoteNullifier: Data
    let cmxNew: Data
    let vanCmx: Data
    let govNullifiers: [Data]
    let proof: Data
    let voteRoundId: Data
    let sighash: Data

    init(
        rk: Data, // swiftlint:disable:this identifier_name
        spendAuthSig: Data,
        signedNoteNullifier: Data,
        cmxNew: Data,
        vanCmx: Data,
        govNullifiers: [Data],
        proof: Data,
        voteRoundId: Data,
        sighash: Data
    ) {
        self.rk = rk
        self.spendAuthSig = spendAuthSig
        self.signedNoteNullifier = signedNoteNullifier
        self.cmxNew = cmxNew
        self.vanCmx = vanCmx
        self.govNullifiers = govNullifiers
        self.proof = proof
        self.voteRoundId = voteRoundId
        self.sighash = sighash
    }
}

// MARK: - Voting

struct EncryptedShare: Equatable, Sendable, Codable {
    let c1: Data // swiftlint:disable:this identifier_name
    let c2: Data // swiftlint:disable:this identifier_name
    let shareIndex: UInt32

    // swiftlint:disable:next identifier_name
    init(c1: Data, c2: Data, shareIndex: UInt32) {
        self.c1 = c1
        self.c2 = c2
        self.shareIndex = shareIndex
    }
}

/// Maps to MsgCastVote (zvote/v1/tx.proto).
struct VoteCommitmentBundle: Equatable, Sendable, Codable {
    let vanNullifier: Data
    let voteAuthorityNoteNew: Data
    let voteCommitment: Data
    let proposalId: UInt32
    let proof: Data
    /// Encrypted shares generated by the ZKP #2 builder (5 shares).
    /// These are the exact ciphertexts committed in the vote commitment hash
    /// and must be used for reveal-share payloads.
    let encShares: [EncryptedShare]
    /// Tree anchor height used for the proof.
    let anchorHeight: UInt32
    /// Voting round ID (hex string).
    let voteRoundId: String
    /// Poseidon hash of encrypted share x-coordinates (32 bytes).
    let sharesHash: Data
    /// Per-share blind factors (N x 32 bytes).
    let shareBlindFactors: [Data]
    /// Pre-computed per-share Poseidon commitments (N x 32 bytes).
    let shareComms: [Data]
    /// Compressed r_vpk (32 bytes) for sighash computation and signature verification.
    let rVpkBytes: Data
    /// Spend-auth randomizer alpha_v (32 bytes, LE scalar repr).
    /// Needed to sign the TX2 sighash: rsk_v = ask_v.randomize(&alpha_v).
    let alphaV: Data

    init(
        vanNullifier: Data,
        voteAuthorityNoteNew: Data,
        voteCommitment: Data,
        proposalId: UInt32,
        proof: Data,
        encShares: [EncryptedShare],
        anchorHeight: UInt32,
        voteRoundId: String,
        sharesHash: Data,
        shareBlindFactors: [Data] = [],
        shareComms: [Data] = [],
        rVpkBytes: Data = Data(),
        alphaV: Data = Data()
    ) {
        self.vanNullifier = vanNullifier
        self.voteAuthorityNoteNew = voteAuthorityNoteNew
        self.voteCommitment = voteCommitment
        self.proposalId = proposalId
        self.proof = proof
        self.encShares = encShares
        self.anchorHeight = anchorHeight
        self.voteRoundId = voteRoundId
        self.sharesHash = sharesHash
        self.shareBlindFactors = shareBlindFactors
        self.shareComms = shareComms
        self.rVpkBytes = rVpkBytes
        self.alphaV = alphaV
    }
}

/// Payload sent to helper servers for share delegation (not directly to chain).
struct SharePayload: Equatable, Sendable {
    let sharesHash: Data
    let proposalId: UInt32
    let voteDecision: UInt32
    let encShare: EncryptedShare
    let treePosition: UInt64
    /// All encrypted shares for this vote (needed by helper servers for verification).
    let allEncShares: [EncryptedShare]
    /// Pre-computed per-share Poseidon commitments (N x 32 bytes).
    let shareComms: [Data]
    /// Blind factor for this specific share (32 bytes).
    let primaryBlind: Data
    /// Unix seconds at which the helper should submit the share; 0 = immediate (last-moment).
    var submitAt: UInt64

    init(
        sharesHash: Data, proposalId: UInt32, voteDecision: UInt32, encShare: EncryptedShare,
        treePosition: UInt64, allEncShares: [EncryptedShare] = [], shareComms: [Data] = [],
        primaryBlind: Data = Data(), submitAt: UInt64 = 0
    ) {
        self.sharesHash = sharesHash
        self.proposalId = proposalId
        self.voteDecision = voteDecision
        self.encShare = encShare
        self.treePosition = treePosition
        self.allEncShares = allEncShares
        self.shareComms = shareComms
        self.primaryBlind = primaryBlind
        self.submitAt = submitAt
    }
}

/// Merkle witness for the VAN in the vote commitment tree.
/// Generated by syncing the tree from chain and computing the authentication path.
struct VanWitness: Equatable, Sendable {
    /// 24 sibling hashes (32 bytes each) from leaf to root.
    let authPath: [Data]
    /// Leaf position of the VAN in the tree.
    let position: UInt32
    /// Block height at which the tree was snapshotted.
    let anchorHeight: UInt32

    init(authPath: [Data], position: UInt32, anchorHeight: UInt32) {
        self.authPath = authPath
        self.position = position
        self.anchorHeight = anchorHeight
    }
}

// MARK: - Transactions

/// Computed signature fields for cast-vote TX submission.
/// Returned by signCastVote after ZKP #2 builds the vote commitment bundle.
/// The sighash is computed on-chain from message fields; the client only
/// provides the signature (which was signed over the same sighash).
struct CastVoteSignature: Equatable, Sendable {
    let voteAuthSig: Data

    init(voteAuthSig: Data) {
        self.voteAuthSig = voteAuthSig
    }
}

/// A single key-value attribute from an ABCI event.
struct TxEventAttribute: Equatable, Sendable {
    let key: String
    let value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// An ABCI event emitted during transaction execution (e.g. `cast_vote`, `delegate_vote`).
struct TxEvent: Equatable, Sendable {
    let type: String
    let attributes: [TxEventAttribute]

    init(type: String, attributes: [TxEventAttribute]) {
        self.type = type
        self.attributes = attributes
    }

    func attribute(forKey key: String) -> String? {
        attributes.first { $0.key == key }?.value
    }
}

/// Confirmed transaction with its ABCI events, parsed from the Cosmos SDK
/// `/cosmos/tx/v1beta1/txs/{hash}` endpoint.
struct TxConfirmation: Equatable, Sendable {
    let height: UInt64
    let code: UInt32
    let log: String
    let events: [TxEvent]

    init(height: UInt64, code: UInt32, log: String = "", events: [TxEvent] = []) {
        self.height = height
        self.code = code
        self.log = log
        self.events = events
    }

    /// Find the first event matching a given type.
    func event(ofType type: String) -> TxEvent? {
        events.first { $0.type == type }
    }
}

/// Maps to BroadcastResult from the REST API (api/handler.go).
struct TxResult: Equatable, Sendable {
    let txHash: String
    let code: UInt32
    let log: String

    init(txHash: String, code: UInt32, log: String = "") {
        self.txHash = txHash
        self.code = code
        self.log = log
    }
}

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

// MARK: - Bundle Setup

/// Result of value-aware note bundling.
/// Only bundles meeting the ballot-divisor threshold are created;
/// eligible_weight reflects the total of surviving bundles.
struct BundleSetupResult: Equatable, Sendable {
    let bundleCount: UInt32
    let eligibleWeight: UInt64

    init(bundleCount: UInt32, eligibleWeight: UInt64) {
        self.bundleCount = bundleCount
        self.eligibleWeight = eligibleWeight
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

// MARK: - Witnesses

struct WitnessData: Equatable, Sendable {
    let noteCommitment: Data
    let position: UInt64
    let root: Data
    let authPath: [Data]

    init(noteCommitment: Data, position: UInt64, root: Data, authPath: [Data]) {
        self.noteCommitment = noteCommitment
        self.position = position
        self.root = root
        self.authPath = authPath
    }
}

// MARK: - Recovery

/// Per-bundle delegation status recovered from chain queries after an app crash.
struct DelegationReconciliation: Equatable, Sendable {
    /// Bundle indices whose delegation TXs have already landed on-chain.
    let completedBundleIndices: Set<UInt32>
    /// Recovered VAN positions from on-chain delegate_vote events (bundleIndex -> leafIndex).
    let vanPositions: [UInt32: UInt32]
    /// Total bundles configured for this round.
    let totalBundles: UInt32

    init(completedBundleIndices: Set<UInt32>, vanPositions: [UInt32: UInt32], totalBundles: UInt32) {
        self.completedBundleIndices = completedBundleIndices
        self.vanPositions = vanPositions
        self.totalBundles = totalBundles
    }
}

/// Persisted Keystone bundle signature, matching the in-memory KeystoneBundleSignature
/// but Codable for file-based persistence across app launches.
struct KeystoneBundleSignatureInfo: Equatable, Sendable, Codable {
    let bundleIndex: UInt32
    let sig: Data
    let sighash: Data
    let rk: Data // swiftlint:disable:this identifier_name

    // swiftlint:disable:next identifier_name
    init(bundleIndex: UInt32, sig: Data, sighash: Data, rk: Data) {
        self.bundleIndex = bundleIndex
        self.sig = sig
        self.sighash = sighash
        self.rk = rk
    }
}

// MARK: - Proof Events

enum ProofEvent: Equatable, Sendable {
    case progress(Double)
    case completed(Data)
}

struct DelegationPirPrecomputeResult: Equatable, Sendable {
    let cachedCount: UInt32
    let fetchedCount: UInt32
}

/// Streaming events for vote commitment build (ZKP #2).
/// Keeps bundle payloads separate from generic proof streams used elsewhere.
enum VoteCommitmentBuildEvent: Equatable, Sendable {
    case progress(Double)
    case completed(VoteCommitmentBundle)
}
