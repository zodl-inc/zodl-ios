@preconcurrency import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var votingCrypto: VotingCryptoClient {
        get { self[VotingCryptoClient.self] }
        set { self[VotingCryptoClient.self] = newValue }
    }
}

enum VotingTxHashLookup: Equatable, Sendable {
    case notFound
    case present(String)
}

@DependencyClient
struct VotingCryptoClient {
    // --- State stream (DB → UI, follows SDKSynchronizer pattern) ---
    var stateStream: @Sendable () -> AnyPublisher<VotingDbState, Never>
        = { Empty().eraseToAnyPublisher() }

    /// Re-publish the current DB state for the given round, triggering stateStream subscribers.
    var refreshState: @Sendable (_ roundId: String) async -> Void = { _ in }

    // --- Database lifecycle ---
    var openDatabase: @Sendable (_ path: String) async throws -> Void
    var setWalletId: @Sendable (_ walletId: String) async throws -> Void
    var initRound: @Sendable (_ params: VotingRoundParams, _ sessionJson: String?) async throws -> Void
    var getRoundState: @Sendable (_ roundId: String) async throws -> RoundStateInfo
    var getVotes: @Sendable (_ roundId: String) async throws -> [VoteRecord]
    var listRounds: @Sendable () async throws -> [RoundSummaryInfo]
    var clearRound: @Sendable (_ roundId: String) async throws -> Void
    /// Delete bundle rows with index >= keepCount, removing skipped bundles
    /// so that proof_generated only considers signed+proven bundles.
    var deleteSkippedBundles: @Sendable (_ roundId: String, _ keepCount: UInt32) async throws -> Void

    /// Warm process-lifetime proving-key caches before the first proof needs them.
    var warmProvingCaches: @Sendable () async throws -> Void = {}

    // --- Wallet notes ---
    var getWalletNotes: @Sendable (
        _ walletDbPath: String,
        _ snapshotHeight: UInt64,
        _ networkId: UInt32,
        _ accountUUID: [UInt8]
    ) async throws -> [NoteInfo]

    // --- Bundle management ---
    var setupBundles: @Sendable (_ roundId: String, _ notes: [NoteInfo]) async throws -> BundleSetupResult
    var getBundleCount: @Sendable (_ roundId: String) async throws -> UInt32

    // --- Witness generation & verification ---
    var generateNoteWitnesses: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ walletDbPath: String,
        _ notes: [NoteInfo]
    ) async throws -> [WitnessData]
    var verifyWitness: @Sendable (_ witness: WitnessData) async throws -> Bool

    // --- Crypto operations ---
    /// Reconstruct the account's voting hotkey from its 64-byte stored secret
    /// (the app derives it from the per-account voting hotkey phrase).
    /// Deterministic: the same secret always yields the same hotkey.
    var generateHotkey: @Sendable (_ roundId: String, _ storedSecret: [UInt8]) async throws -> VotingHotkey
    /// Build a voting PCZT for Keystone signing.
    /// The PCZT's single Orchard action IS the voting dummy action, so Keystone's
    /// SpendAuth signature will be over the voting-bound ZIP-244 sighash.
    /// The crate gathers notes and the account FVK from the wallet DB itself
    /// (UFVK-only Keystone accounts included) — no seed or FVK crosses this API.
    var buildVotingPczt: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ walletDbPath: String,
        _ accountUuid: String,
        _ hotkeySecret: [UInt8],
        _ roundName: String
    ) async throws -> VotingPcztResult
    var storeTreeState: @Sendable (_ roundId: String, _ treeState: Data) async throws -> Void
    var extractSpendAuthSignatureFromSignedPczt: @Sendable (
        _ signedPczt: Data,
        _ actionIndex: UInt32
    ) throws -> Data
    /// Extract the ZIP-244 shielded sighash from finalized PCZT bytes.
    /// Returns the 32-byte sighash that Keystone signed internally.
    var extractPcztSighash: @Sendable (_ pcztBytes: Data) throws -> Data
    /// Resolve the round PIR endpoint, fetch ZKP #1 IMT proofs, and cache them in the voting DB.
    /// Requires `buildVotingPczt` to have stored delegation data for this bundle first.
    var precomputeDelegationPir: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64,
        _ networkId: UInt32
    ) async throws -> DelegationPirPrecomputeResult
    /// Build and prove the real delegation ZKP (#1). Long-running.
    /// Loads data from voting DB and wallet DB, fetches IMT proofs from server,
    /// generates a real Halo2 proof, and reports progress.
    /// Requires `buildVotingPczt` to have been called first for this bundle —
    /// it stores the delegation data (alpha, secrets, sighash) needed by the prover.
    /// Pass every PIR endpoint configured for the round, plus the round's
    /// expected snapshot height. The SDK probes each endpoint's `GET /root`
    /// and uses the first endpoint (in config order) whose served snapshot
    /// height equals `expectedSnapshotHeight` exactly. Endpoints that are
    /// behind, ahead, missing snapshot metadata, or unreachable are excluded.
    /// If none match, the stream finishes with a `PirSnapshotResolverError`
    /// — there is no fallback to mismatched endpoints.
    var buildAndProveDelegation: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ walletDbPath: String,
        _ accountUuid: String,
        _ hotkeySecret: [UInt8],
        _ roundName: String,
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64
    ) -> AsyncThrowingStream<ProofEvent, Error>
        = { _, _, _, _, _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    /// Extract Orchard FVK bytes from a UFVK string.
    var extractOrchardFvkFromUfvk: @Sendable (_ ufvkStr: String, _ networkId: UInt32) throws -> Data
    /// One-shot vote commit: proof, share split + encryption, cast-vote
    /// signature, and recovery persistence all happen inside the crate; the
    /// completed event carries the bundle (including `voteAuthSig`).
    /// Idempotent — re-running after a crash returns the persisted commit.
    var buildVoteCommitment: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ hotkeySeed: [UInt8],
        _ networkId: UInt32,
        _ proposalId: UInt32,
        _ choice: VoteChoice,
        _ numOptions: UInt32,
        _ vanAuthPath: [Data],
        _ vanPosition: UInt32,
        _ anchorHeight: UInt32,
        _ singleShare: Bool
    ) -> AsyncThrowingStream<VoteCommitmentBuildEvent, Error>
        = { _, _, _, _, _, _, _, _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    /// Record the confirmed vote-commitment tree position (from the cast-vote
    /// TX's `leaf_index`) into crate recovery state.
    var recordVcPosition: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32,
        _ vcTreePosition: UInt64
    ) async throws -> Void
    /// Reconstruct a committed vote (bundle + helper-share payloads at the
    /// stored VC position) from crate recovery state. Throws when no
    /// committed vote exists for the key.
    var recoverCommittedVote: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32
    ) async throws -> RecoveredCommittedVote
    /// Crate-scheduled helper-share submit time (Unix seconds, 0 = immediate).
    /// Pass 8 fresh CSPRNG bytes per share; the crate owns the sampling.
    var scheduledShareSubmitAt: @Sendable (
        _ nowSeconds: UInt64,
        _ ceremonyStartSeconds: UInt64,
        _ voteEndSeconds: UInt64,
        _ singleShare: Bool,
        _ entropy: [UInt8]
    ) throws -> UInt64
    /// Reconstruct the full chain-ready delegation TX payload from DB + seed.
    /// Call after `buildAndProveDelegation` completes. The wallet seed is used
    /// only to sign the crate-produced signing request locally; it never
    /// enters the voting crate.
    var getDelegationSubmission: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ walletDbPath: String,
        _ accountUuid: String,
        _ hotkeySecret: [UInt8],
        _ roundName: String,
        _ senderSeed: [UInt8]
    ) async throws -> DelegationRegistration
    /// Reconstruct the delegation TX payload using a Keystone-provided signature.
    /// Uses the externally-provided signature and ZIP-244 sighash instead of
    /// deriving `ask` from seed.
    var getDelegationSubmissionWithKeystoneSig: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ keystoneSig: Data,
        _ keystoneSighash: Data
    ) async throws -> DelegationRegistration
    var storeVanPosition: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ position: UInt32) async throws -> Void
    var syncVoteTree: @Sendable (_ roundId: String, _ nodeUrl: String) async throws -> UInt32
    var generateVanWitness: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ anchorHeight: UInt32) async throws -> VanWitness
    var markVoteSubmitted: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ proposalId: UInt32) async throws -> Void
    /// Drop the in-memory TreeClient so the next `syncVoteTree` starts fresh.
    /// Recovers from stale state after commitment tree timeout.
    var resetTreeClient: @Sendable () async throws -> Void
    /// Extract the Orchard nc_root from a protobuf-encoded TreeState.
    var extractNcRoot: @Sendable (_ treeStateBytes: Data) throws -> Data

    // --- Recovery state (stored in the voting SQLite DB) ---

    /// Store the TX hash of a delegation bundle that has been submitted to the chain.
    var storeDelegationTxHash: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ txHash: String
    ) async throws -> Void
    /// Load a previously stored delegation TX hash for a bundle.
    /// Returns `.notFound` when the DB has no row; `throws` reserved for FFI failures.
    var getDelegationTxHash: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32
    ) async throws -> VotingTxHashLookup
    /// Persist a vote TX hash for a bundle + proposal immediately after submission.
    var storeVoteTxHash: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32,
        _ txHash: String
    ) async throws -> Void
    /// Load a previously stored vote TX hash.
    /// Returns `.notFound` when the DB has no row; `throws` reserved for FFI failures.
    var getVoteTxHash: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32
    ) async throws -> VotingTxHashLookup
    /// Persist a Keystone bundle signature so it survives app restarts.
    var storeKeystoneBundleSignature: @Sendable (
        _ roundId: String,
        _ info: KeystoneBundleSignatureInfo
    ) async throws -> Void
    /// Load all persisted Keystone bundle signatures for a round.
    var loadKeystoneBundleSignatures: @Sendable (
        _ roundId: String
    ) async throws -> [KeystoneBundleSignatureInfo]
    /// Clear recovery state for a round (keystone sigs, TX hashes).
    var clearRecoveryState: @Sendable (
        _ roundId: String
    ) async throws -> Void

    // --- Share delegation tracking ---

    /// Record a share delegation after sending to helper servers. The crate
    /// computes and persists the share nullifier itself — pass an empty
    /// `nullifier` (non-empty values are only shape-validated).
    var recordShareDelegation: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ proposalId: UInt32, _ shareIndex: UInt32, _ sentToURLs: [String], _ nullifier: [UInt8], _ submitAt: UInt64) async throws -> Void
    /// Get all share delegations for a round.
    var getShareDelegations: @Sendable (_ roundId: String) async throws -> [VotingShareDelegation]
    /// Get unconfirmed share delegations for a round.
    var getUnconfirmedDelegations: @Sendable (_ roundId: String) async throws -> [VotingShareDelegation]
    /// Mark a share delegation as confirmed on-chain.
    var markShareConfirmed: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ proposalId: UInt32, _ shareIndex: UInt32) async throws -> Void
    /// Append new server URLs to a share delegation's sent_to_urls.
    var addSentServers: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ proposalId: UInt32, _ shareIndex: UInt32, _ newURLs: [String]) async throws -> Void
}
