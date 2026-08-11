#if VOTING_ENABLED
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
    var openDatabase: @Sendable (_ path: String, _ networkId: UInt32) async throws -> Void
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
    var generateHotkey: @Sendable (_ roundId: String, _ seed: [UInt8]) async throws -> VotingHotkey
    /// Build a voting PCZT for Keystone signing.
    /// The PCZT's single Orchard action IS the voting dummy action, so Keystone's
    /// SpendAuth signature will be over the voting-bound ZIP-244 sighash.
    var buildVotingPczt: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ notes: [NoteInfo],
        _ senderSeed: [UInt8],
        _ hotkeySeed: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ roundName: String,
        _ orchardFvkOverride: Data?,
        _ keystoneSeedFingerprintOverride: Data?
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
        _ bundleNotes: [NoteInfo],
        _ senderSeed: [UInt8],
        _ hotkeySeed: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64
    ) -> AsyncThrowingStream<ProofEvent, Error>
        = { _, _, _, _, _, _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    /// Extract Orchard FVK bytes from a UFVK string.
    var extractOrchardFvkFromUfvk: @Sendable (_ ufvkStr: String, _ networkId: UInt32) throws -> Data
    /// Build, sign, and persist the cast-vote commitment for one proposal in a single call.
    /// Replaces the former three-member sequence — build the commitment, sign the cast vote,
    /// build the share payloads — because `zcash_voting` now owns that orchestration
    /// internally and the intermediate artifacts are no longer separable steps.
    ///
    /// `voteCommitmentTreePosition` must be `0` for the provisional call in the sanctioned
    /// sequence (plan Task 9, spec `CHP_DESIGN.md` §3/A2 step 1) — the true position is not
    /// known until the cast-vote transaction confirms on chain. The call is idempotent:
    /// repeating it for the same (round, bundle, proposal) returns the persisted recovery
    /// bundle rather than re-proving.
    ///
    /// `hotkeyStoredSecret` is the voting hotkey's stored secret bytes (plan Task 10), not a
    /// derived seed. The returned pair feeds `VotingAPIClient.submitVoteCommitment(bundle:
    /// signature:)` verbatim — `bundle.sharesHash` is populated empty; `submitVoteCommitment`'s
    /// wire-body construction never reads it (verified: `VotingAPIClientLiveKey.swift:912-933`).
    // swiftlint:disable:next function_parameter_count
    var commitVote: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ hotkeyStoredSecret: [UInt8],
        _ proposalId: UInt32,
        _ choice: VoteChoice,
        _ numOptions: UInt32,
        _ voteCommitmentTreePosition: UInt64,
        _ vanAuthPath: [Data],
        _ vanPosition: UInt32,
        _ vanAnchorHeight: UInt32,
        _ singleShare: Bool
    ) async throws -> (bundle: VoteCommitmentBundle, signature: CastVoteSignature)
    /// Produce this wallet's own SpendAuth signature for one delegation bundle.
    /// The software counterpart of the Keystone QR round-trip: `zcash_voting` 2.0 no longer
    /// derives account keys or signs for its callers, and prescribes exactly this instead —
    /// load the bundle's signing request, derive the account SpendAuth key from the seed,
    /// randomize it with the request's randomizer, sign the request's sighash. All of it
    /// happens inside the SDK; the seed goes in, only the detached signature comes back.
    /// Feed the result straight into `getDelegationSubmission`.
    var signDelegationRequest: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ senderSeed: [UInt8],
        _ hotkeyStoredSecret: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ roundName: String
    ) async throws -> (signature: Data, sighash: Data)

    /// Reconstruct the chain-ready delegation TX payload from a previously-produced
    /// SpendAuth signature + ZIP-244 sighash. `zcash_voting` no longer derives account keys
    /// or signs on the caller's behalf, so an externally-produced signature is the only
    /// remaining path — this one member now serves both the Keystone-signed call site
    /// (`VotingCoordFlowCoordinator.swift:2900`, signature off the scanned QR) and the
    /// software-signed call sites (`:3557`, `:3591` — see this task's step 8.10 finding for
    /// their unresolved signature source).
    var getDelegationSubmission: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ signature: Data,
        _ sighash: Data
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
    /// Load a persisted vote commitment bundle (nil if never stored).
    var getVoteCommitmentBundle: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32
    ) async throws -> VoteCommitmentBundle?
    /// Load a persisted vote commitment bundle with its VC tree position (needed for share resubmission).
    var getVoteCommitmentBundleWithPosition: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32
    ) async throws -> (bundle: VoteCommitmentBundle, vcTreePosition: UInt64)?
    /// Clear recovery state for a round (keystone sigs, TX hashes).
    var clearRecoveryState: @Sendable (
        _ roundId: String
    ) async throws -> Void

    // --- Share delegation tracking ---

    /// Compute the nullifier for a vote share (pure function, no DB needed).
    var computeShareNullifier: @Sendable (_ voteCommitment: [UInt8], _ shareIndex: UInt32, _ primaryBlind: [UInt8]) throws -> String
    /// Record a share delegation after sending to helper servers.
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
#endif
