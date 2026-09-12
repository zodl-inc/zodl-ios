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

/// The app's whole voting surface on `zcash_voting`.
///
/// Two halves, and the split matters. The store-scoped members read and write
/// the sidecar database directly and need nothing but an open database. The
/// round-scoped members go through a ``VotingRoundSession``, which is opened
/// once per round with ``openRoundSession`` and is where planning, bundle
/// setup, proving, signing and driving all happen; calling one of them for a
/// round with no open session throws ``VotingSessionError/notOpen(roundId:)``.
///
/// `runRound` and `trackShares` are exclusive per round: a second one while the
/// first is in flight throws ``VotingRustBackendError/sessionBusy``, because two
/// drivers over one round would contend for its rows and their events would be
/// indistinguishable.
@DependencyClient
struct VotingCryptoClient {
    // MARK: - State stream (DB -> UI, follows the SDKSynchronizer pattern)

    var stateStream: @Sendable () -> AnyPublisher<VotingDbState, Never>
        = { Empty().eraseToAnyPublisher() }

    /// Re-publish the current DB state, triggering `stateStream` subscribers.
    ///
    /// The round's own state is the session plan now (`sessionPlan`), which is
    /// read where it is needed rather than pushed, so nothing publishes a new
    /// value here yet.
    var refreshState: @Sendable (_ roundId: String) async -> Void = { _ in }

    // MARK: - Process-wide proving

    /// Fix the process-wide proving policy.
    ///
    /// Must run before ``warmProvingCaches`` and before the first proof: either
    /// of those starts the pool on the crate's own default policy, and the
    /// policy asked for here is then not the one in force.
    var configureProving: @Sendable (_ policy: VotingProvingPolicy) async throws -> Void

    /// Warm process-lifetime proving-key caches before the first proof needs
    /// them.
    var warmProvingCaches: @Sendable () async throws -> Void = {}

    // MARK: - Wallet teardown

    /// Open the window in which nothing may open the sidecar or a round session, for a reset or
    /// a heal that is about to close the database and delete its file. Balanced by
    /// ``endWalletTeardown``. See ``VotingTeardown``.
    var beginWalletTeardown: @Sendable () -> Void = { }
    var endWalletTeardown: @Sendable () -> Void = { }
    /// The teardown generation an open should capture, or nil while one is under way -- in which
    /// case the open must not start at all.
    var teardownGenerationIfIdle: @Sendable () -> UInt64? = { 0 }
    /// Whether an open that captured `capturedGeneration` may still go ahead, asked again
    /// immediately before the call that would create the database or the session.
    var teardownAllowsOpen: @Sendable (_ capturedGeneration: UInt64) -> Bool = { _ in true }
    /// Announced when a teardown begins, so a flow that is still alive can stop its in-flight
    /// opens and give back the sessions it holds rather than wait to be refused.
    var teardownBegan: @Sendable () -> AnyPublisher<Void, Never> = { Empty().eraseToAnyPublisher() }

    // MARK: - Database lifecycle

    var openDatabase: @Sendable (_ path: String, _ networkId: UInt32) async throws -> Void
    var setWalletId: @Sendable (_ walletId: String) async throws -> Void
    /// Close every open round session, then the store itself.
    var closeDatabase: @Sendable () async -> Void

    // MARK: - Store-scoped reads and maintenance

    var listRounds: @Sendable () async throws -> [VotingRoundSummary]
    /// Plan a round from the sidecar alone, without opening a session for it.
    var roundPlan: @Sendable (_ roundId: String, _ proposalIds: [UInt32]) async throws -> VotingRoundPlan
    /// The rounds of every wallet that still owe helper-share work.
    var pendingShareRounds: @Sendable () async throws -> [VotingPendingShareRound]
    /// Bring the round's local vote-commitment tree up to the node's, answering
    /// with the height it reached.
    var syncVoteTree: @Sendable (_ roundId: String, _ nodeUrl: String) async throws -> UInt32
    /// Drop the round's cached vote tree so the next sync starts from scratch.
    var resetVoteTree: @Sendable (_ roundId: String) async throws -> Void
    /// Clear per-session state for a round, leaving signed and registered
    /// bundles alone -- the safe "resume in place" cleanup.
    var resetSessionState: @Sendable (_ roundId: String) async throws -> Void
    var deleteRound: @Sendable (_ roundId: String, _ discardingRecovery: Bool) async throws -> Void
    /// Delete bundle rows with index >= `keepCount`, so the skipped bundles stop
    /// counting towards the round's remaining work.
    var deleteSkippedBundles: @Sendable (_ roundId: String, _ keepCount: UInt32) async throws -> Void
    /// Retry a combined delegate-and-vote cast the chain refused, answering
    /// whether there was one to retry.
    var retryBlockedCombinedCast: @Sendable (_ roundId: String, _ bundleIndex: UInt32) async throws -> Bool
    /// Forget the recorded ballot decisions for the named proposals.
    var clearBallotIntents: @Sendable (_ roundId: String, _ proposalIds: [UInt32]) async throws -> Void
    /// The Keystone signatures stored for a round.
    var keystoneSignatures: @Sendable (_ roundId: String) async throws -> [VotingKeystoneSignatureRecord]

    // MARK: - Round session lifecycle

    /// Open a round session, replacing any session the round already has.
    ///
    /// The route is fixed for the session's whole life and `.tor` fails closed:
    /// a session that cannot have the Tor route is refused rather than opened
    /// over a direct connection.
    var openRoundSession: @Sendable (
        _ inputs: VotingSessionInputs,
        _ binding: VotingSessionBinding,
        _ route: VotingTransportRoute,
        _ epoch: UInt64
    ) async throws -> Void
    var closeRoundSession: @Sendable (_ roundId: String) async -> Void
    var closeAllRoundSessions: @Sendable () async -> Void
    /// Stop the round's bounded passes. Permanent: a cancelled session is
    /// finished, not paused, and the round is reopened rather than resumed.
    var cancelRoundSession: @Sendable (_ roundId: String) async -> Void
    /// Move the round's submission epoch, invalidating passes that captured an
    /// older one.
    var setOperationEpoch: @Sendable (_ roundId: String, _ epoch: UInt64) async -> Void

    // MARK: - Round session work

    var sessionPlan: @Sendable (_ roundId: String) async throws -> VotingRoundPlan
    /// Record ballot decisions and answer with the refreshed plan.
    var setBallotIntents: @Sendable (_ roundId: String, _ intents: [VotingBallotIntent]) async throws -> VotingRoundPlan
    /// Create the round's row and its delegation bundle rows. Reads the wallet,
    /// so an account with nothing eligible is refused as a typed
    /// ``VotingError`` rather than as a fault.
    var setupBundles: @Sendable (_ roundId: String) async throws -> VotingBundleLayout
    /// Whether this account can vote in the round, persisting nothing.
    var eligibility: @Sendable (_ roundId: String) async throws -> VotingEligibilityReport
    /// Persist one bundle's witnesses and padded secrets and warm its PIR rows.
    var precomputePir: @Sendable (_ roundId: String, _ bundleIndex: UInt32) async throws -> VotingPirPrecomputeReport
    /// Generate one bundle's delegation proof ahead of a run, or report the
    /// persisted one it reused.
    ///
    /// Cancelling the consuming task stops the stream but not a proof already
    /// running: the crate takes no cancellation signal for one, and a proof that
    /// finishes is persisted and reused, so nothing is wasted.
    var precomputeDelegationProof: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32
    ) -> AsyncThrowingStream<VotingDelegationProofEvent, Error>
        = { _, _ in AsyncThrowingStream { $0.finish() } }
    /// The redacted PCZTs a Keystone device signs, one per named bundle, in the
    /// order named.
    var keystoneSigningRequests: @Sendable (
        _ roundId: String,
        _ bundleIndices: [UInt32]
    ) async throws -> [VotingKeystoneSigningRequest]
    /// Lift the signatures off the PCZTs a Keystone device returned and store
    /// them. One atomic idempotent batch.
    var storeKeystoneSignatures: @Sendable (
        _ roundId: String,
        _ signed: [VotingKeystoneSignedBundle]
    ) async throws -> VotingKeystoneSignatureBatchResult
    /// Drive the round to quiescence, narrating as it goes.
    ///
    /// The driver itself does not fail: a run that could do nothing says why
    /// through the report's quiescence, which arrives as the stream's last
    /// element. A thrown error is the call around it -- a session that is closed
    /// or already driving, or a signer this host cannot build.
    var runRound: @Sendable (
        _ roundId: String,
        _ signer: VotingDelegationSigner,
        _ policy: VotingRoundDrivePolicy
    ) -> AsyncThrowingStream<VotingRoundRunEvent, Error>
        = { _, _, _ in AsyncThrowingStream { $0.finish() } }
    /// Drive the round's unconfirmed helper shares to confirmation, on the same
    /// terms as `runRound` and without a signer.
    var trackShares: @Sendable (
        _ roundId: String,
        _ policy: VotingShareTrackingPolicy
    ) -> AsyncThrowingStream<VotingShareTrackingRunEvent, Error>
        = { _, _ in AsyncThrowingStream { $0.finish() } }

    // MARK: - Key material

    /// Generate a new voting hotkey for `networkId`. The application must
    /// persist the returned `storedSecret` -- it cannot be recovered from the
    /// wallet seed, and calling this again produces an unrelated hotkey rather
    /// than recovering the previous one.
    var generateHotkey: @Sendable (_ networkId: UInt32) async throws -> VotingHotkey
    /// Extract Orchard FVK bytes from a UFVK string.
    var extractOrchardFvkFromUfvk: @Sendable (_ ufvkStr: String, _ networkId: UInt32) throws -> Data
    /// Extract the Orchard nc_root from a protobuf-encoded TreeState.
    var extractNcRoot: @Sendable (_ treeStateBytes: Data) throws -> Data
}
#endif
