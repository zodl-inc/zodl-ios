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
    /// Hash of the transaction that broadcast this delegation, when it had
    /// been broadcast by the time the secrets were captured.
    ///
    /// Present so this entry carries everything `import_delegation_capability`
    /// needs -- it inserts a bundle from exactly `(round_id, wallet_id,
    /// bundle_index, van_comm_rand, gov_comm, total_note_value, address_index,
    /// delegation_tx_hash)` and leaves every other column NULL by design.
    ///
    /// Nil is a legitimate state, not a partial capture: the hash is stored
    /// only after the delegation is broadcast, so nil generally means nothing
    /// was broadcast and there is nothing to resume.
    ///
    /// Decoding an escrow written before this field existed yields nil, which
    /// is why it is optional rather than a schema-version bump.
    let delegationTxHash: String?
    /// Where this entry came from.
    ///
    /// Inferring it was tried and does not work. A carved entry and a live
    /// capture are otherwise identical on disk, and `delegationTxHash` is not
    /// a reliable discriminator: a carve that found no hash leaves it nil,
    /// exactly like a live capture. Recording the origin makes the difference
    /// a fact rather than a guess, which is what lets a diagnosis say "your
    /// data was lost and we have it back" only when that is true.
    let source: Source
    let createdAt: Date

    /// An escrow written before `source` existed decodes as a live capture.
    ///
    /// That is the conservative reading: it makes a diagnosis claim loss only
    /// where an entry positively says it was recovered, so an older file can
    /// never produce "your data was lost" on a round where nothing was.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roundId = try container.decode(String.self, forKey: .roundId)
        bundleIndex = try container.decode(UInt32.self, forKey: .bundleIndex)
        vanCommRand = try container.decode(Data.self, forKey: .vanCommRand)
        van = try container.decode(Data.self, forKey: .van)
        totalNoteValue = try container.decode(UInt64.self, forKey: .totalNoteValue)
        delegationTxHash = try container.decodeIfPresent(String.self, forKey: .delegationTxHash)
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .liveCapture
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    init(
        roundId: String,
        bundleIndex: UInt32,
        vanCommRand: Data,
        van: Data,
        totalNoteValue: UInt64,
        delegationTxHash: String?,
        source: Source,
        createdAt: Date
    ) {
        self.roundId = roundId
        self.bundleIndex = bundleIndex
        self.vanCommRand = vanCommRand
        self.van = van
        self.totalNoteValue = totalNoteValue
        self.delegationTxHash = delegationTxHash
        self.source = source
        self.createdAt = createdAt
    }

    enum Source: String, Equatable, Sendable, Codable {
        /// Captured while the delegation was being built, before any
        /// broadcast. Ordinary bookkeeping: its presence says nothing about
        /// whether anything was lost.
        case liveCapture
        /// Carved back out of a wiped database. Its presence is evidence that
        /// the round WAS cleared and rebuilt, because recovery escrows only
        /// where it found a replacement for a secret the live copy no longer
        /// holds.
        case recovered
    }
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
