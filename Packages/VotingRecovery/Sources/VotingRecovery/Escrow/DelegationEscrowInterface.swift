import Dependencies
import DependenciesMacros
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
/// `ON DELETE CASCADE`, so a wipe is terminal for that round's voting rights
/// unless the value was copied out first. This is that copy, and the SDK's
/// guarded restore (`restoreRecoveredDelegation`) is the only way back in:
/// it recomputes the commitment from this blinding before it writes anything.
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
    /// `bundles.wallet_id` of the row this was carved from. Empty for a live
    /// capture, or an escrow written before the field existed.
    let walletId: String
    /// Hotkey address index; the import stores zero.
    let addressIndex: UInt32
    /// Position of the VAN in the round's tree, once confirmed.
    let vanLeafPosition: UInt32?
    /// Where the row was found, for logs and support. Never carries content.
    let provenance: String
    /// `VotingDatabaseRecovery.Source.rank`; higher is more trusted. One
    /// bundle may hold several candidates, and the restore offers the best
    /// the chain has not refused.
    let provenanceRank: Int
    /// Set when the chain refused this candidate's leaf, so the restore
    /// never offers it again.
    let rejectedAt: Date?

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
        walletId = try container.decodeIfPresent(String.self, forKey: .walletId) ?? ""
        addressIndex = try container.decodeIfPresent(UInt32.self, forKey: .addressIndex) ?? 0
        vanLeafPosition = try container.decodeIfPresent(UInt32.self, forKey: .vanLeafPosition)
        provenance = try container.decodeIfPresent(String.self, forKey: .provenance) ?? "unknown"
        provenanceRank = try container.decodeIfPresent(Int.self, forKey: .provenanceRank) ?? 0
        rejectedAt = try container.decodeIfPresent(Date.self, forKey: .rejectedAt)
    }

    init(
        roundId: String,
        bundleIndex: UInt32,
        vanCommRand: Data,
        van: Data,
        totalNoteValue: UInt64,
        delegationTxHash: String?,
        source: Source,
        createdAt: Date,
        walletId: String = "",
        addressIndex: UInt32 = 0,
        vanLeafPosition: UInt32? = nil,
        provenance: String = "unknown",
        provenanceRank: Int = 0,
        rejectedAt: Date? = nil
    ) {
        self.roundId = roundId
        self.bundleIndex = bundleIndex
        self.vanCommRand = vanCommRand
        self.van = van
        self.totalNoteValue = totalNoteValue
        self.delegationTxHash = delegationTxHash
        self.source = source
        self.createdAt = createdAt
        self.walletId = walletId
        self.addressIndex = addressIndex
        self.vanLeafPosition = vanLeafPosition
        self.provenance = provenance
        self.provenanceRank = provenanceRank
        self.rejectedAt = rejectedAt
    }

    enum Source: String, Equatable, Sendable, Codable {
        /// Captured while the delegation was being built, before any
        /// broadcast. Ordinary bookkeeping: its presence says nothing about
        /// whether anything was lost.
        case liveCapture
        /// Carved out of the preserved files. Every schema-consistent row is
        /// escrowed, the live one included, each with its provenance; a bundle
        /// holding more than one distinct blinding is the evidence that the
        /// round was cleared and rebuilt.
        case recovered
    }
}

/// Held by one recovery run for its whole duration. The store accepts the
/// run's entries only while no wallet reset has happened since it was taken.
struct DelegationEscrowLease: Equatable, Sendable {
    let generation: UInt64
}

/// Durable, wallet-scoped escrow for delegation secrets that `clear_round`
/// would otherwise destroy irrecoverably.
@DependencyClient
struct DelegationEscrowClient {
    /// Persists one candidate. Keyed by `(roundId, bundleIndex, vanCommRand,
    /// van)`: a bundle keeps every distinct image recovered for it, and a live
    /// capture never displaces a recovered copy of the same candidate.
    var record: @Sendable (_ entry: DelegationEscrowEntry) async throws -> Void
    /// A lease for one recovery run; see `recordRecovered`.
    var beginRecovery: @Sendable () async -> DelegationEscrowLease = { DelegationEscrowLease(generation: 0) }
    /// Persists one candidate a recovery run found. Throws
    /// `DelegationEscrowError.staleLease`, writing nothing that survives, once
    /// a wallet reset has happened since `lease` was taken, so the previous
    /// wallet's secrets can never be written back for its replacement.
    var recordRecovered: @Sendable (_ entry: DelegationEscrowEntry, _ lease: DelegationEscrowLease) async throws -> Void
    /// Every escrowed bundle for one round, in bundle-index order.
    var entries: @Sendable (_ roundId: String) async throws -> [DelegationEscrowEntry]
    /// Whether this round has any escrowed delegation left to protect.
    var holdsDelegation: @Sendable (_ roundId: String) async -> Bool = { _ in false }
    /// Drops one round's entries. Call only once its delegation is confirmed
    /// and its votes are cast -- never as part of a retry.
    var forget: @Sendable (_ roundId: String) async throws -> Void
    /// Stamps one candidate as refused by the chain, so a restore never
    /// offers it again. Named by its blinding, since one bundle may hold
    /// several candidates.
    var markRejected: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ vanCommRand: Data) async throws -> Void
    /// Drops everything. Wallet-reset scope only: the escrow is as
    /// wallet-specific as `voting.sqlite3` and must not outlive it.
    var reset: @Sendable () async -> Void
}
