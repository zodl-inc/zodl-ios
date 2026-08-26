#if VOTING_ENABLED
import ComposableArchitecture
import Foundation

extension DependencyValues {
    var delegationEscrow: DelegationEscrowClient {
        get { self[DelegationEscrowClient.self] }
        set { self[DelegationEscrowClient.self] = newValue }
    }
}

/// One bundle's delegation secrets, captured at the only moment the app ever
/// holds them.
///
/// `vanCommRand` is sampled from `OsRng` inside the Rust core and is never
/// derived from the wallet seed, so it cannot be recomputed. It reaches Swift
/// exactly once, as `VotingPcztResult.vanCommRand`, and is otherwise persisted
/// only in `voting.sqlite3`. Deleting a round takes `bundles` with it via
/// `ON DELETE CASCADE`, and the FFI exposes no way to write the value back --
/// so a wipe is terminal for that round's voting rights unless the value was
/// copied out first. This is that copy.
struct DelegationEscrowEntry: Equatable, Sendable, Codable {
    /// Canonical 64-character lowercase hex round identifier.
    let roundId: String
    let bundleIndex: UInt32
    /// 32-byte Pallas blinding factor for the VAN commitment.
    let vanCommRand: Data
    /// 32-byte VAN commitment this blinding factor opens. Published on chain,
    /// so it doubles as a self-check: recomputing the VAN from `vanCommRand`
    /// must reproduce it.
    let van: Data
    /// Bundle weight in zatoshi, the third VAN preimage element.
    let totalNoteValue: UInt64
    let createdAt: Date
}

/// Durable, wallet-scoped escrow for delegation secrets that `clear_round`
/// would otherwise destroy irrecoverably.
@DependencyClient
struct DelegationEscrowClient {
    /// Persists one bundle's secrets. Overwrites any entry for the same
    /// `(roundId, bundleIndex)` -- re-running the delegation samples fresh
    /// randomness, and the newest sample is the one the chain will see.
    var record: @Sendable (_ entry: DelegationEscrowEntry) async throws -> Void
    /// Every escrowed bundle for one round, in bundle-index order.
    var entries: @Sendable (_ roundId: String) async throws -> [DelegationEscrowEntry]
    /// Whether this round has any escrowed delegation left to protect.
    var holdsDelegation: @Sendable (_ roundId: String) async -> Bool = { _ in false }
    /// Drops one round's entries. Call only once its delegation is confirmed
    /// and its votes are cast -- never as part of a retry.
    var forget: @Sendable (_ roundId: String) async throws -> Void
    /// Drops everything. Wallet-reset scope only: the escrow is as
    /// wallet-specific as `voting.sqlite3` and must not outlive it.
    var reset: @Sendable () async -> Void
}
#endif
