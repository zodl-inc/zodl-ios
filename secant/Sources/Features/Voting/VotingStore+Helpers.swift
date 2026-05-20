import Foundation
import ComposableArchitecture

// MARK: - Draft Persistence

extension Voting {
    private static let draftPrefix = "voting.draftVotes."
    private static let voteRecordPrefix = "voting.voteRecord."

    /// Persisted record of when a round's vote submission fully completed,
    /// the voting weight at that moment, and how many proposals were included.
    /// Survives app termination so the Results screen can render
    /// "Voted Feb 15 - Voting Power X.XXX ZEC" and the polls list can show
    /// the Voted state days after submission, even though the live session
    /// state is per-session.
    struct VoteRecord: Equatable {
        let votedAt: Date
        let votingWeight: UInt64
        let proposalCount: Int

        init(votedAt: Date, votingWeight: UInt64, proposalCount: Int) {
            self.votedAt = votedAt
            self.votingWeight = votingWeight
            self.proposalCount = proposalCount
        }
    }

    private static func voteRecordKey(walletId: String, roundId: String) -> String {
        "\(voteRecordPrefix)\(walletId)|\(roundId)"
    }

    static func persistVoteRecord(_ record: VoteRecord, walletId: String, roundId: String) {
        let key = voteRecordKey(walletId: walletId, roundId: roundId)
        UserDefaults.standard.set(
            [
                "votedAt": record.votedAt.timeIntervalSince1970,
                "votingWeight": NSNumber(value: record.votingWeight),
                "proposalCount": NSNumber(value: record.proposalCount)
            ],
            forKey: key
        )
    }

    static func loadVoteRecord(walletId: String, roundId: String) -> VoteRecord? {
        let key = voteRecordKey(walletId: walletId, roundId: roundId)
        guard let raw = UserDefaults.standard.dictionary(forKey: key),
              let votedAtUnix = raw["votedAt"] as? Double,
              let weight = (raw["votingWeight"] as? NSNumber)?.uint64Value else {
            return nil
        }
        // proposalCount was added later — older records default to 0 and the
        // view falls back to the round's full proposal count for display.
        let count = (raw["proposalCount"] as? NSNumber)?.intValue ?? 0
        return VoteRecord(
            votedAt: Date(timeIntervalSince1970: votedAtUnix),
            votingWeight: weight,
            proposalCount: count
        )
    }

    static func clearPersistedVoteRecord(walletId: String, roundId: String) {
        UserDefaults.standard.removeObject(forKey: voteRecordKey(walletId: walletId, roundId: roundId))
    }

    /// A round-level vote record is only valid once all drafts are gone.
    /// Older builds wrote it too early, so clear it if there is still
    /// outstanding editable work for the round.
    static func loadCompletedVoteRecord(walletId: String, roundId: String) -> VoteRecord? {
        guard loadDrafts(walletId: walletId, roundId: roundId).isEmpty else {
            clearPersistedVoteRecord(walletId: walletId, roundId: roundId)
            return nil
        }
        return loadVoteRecord(walletId: walletId, roundId: roundId)
    }

    private static func draftKey(walletId: String, roundId: String) -> String {
        "\(draftPrefix)\(walletId)|\(roundId)"
    }

    /// Persist draft votes to UserDefaults so they survive app termination.
    static func persistDrafts(_ drafts: [UInt32: VoteChoice], walletId: String, roundId: String) {
        let key = draftKey(walletId: walletId, roundId: roundId)
        if drafts.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            let encoded = drafts.reduce(into: [String: UInt32]()) { dict, entry in
                dict[String(entry.key)] = entry.value.index
            }
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    /// Load persisted draft votes for a round.
    static func loadDrafts(walletId: String, roundId: String) -> [UInt32: VoteChoice] {
        let key = draftKey(walletId: walletId, roundId: roundId)
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: UInt32] else {
            return [:]
        }
        return raw.reduce(into: [UInt32: VoteChoice]()) { dict, entry in
            if let proposalId = UInt32(entry.key) {
                dict[proposalId] = .option(entry.value)
            }
        }
    }

    /// Remove all persisted drafts for a round.
    static func clearPersistedDrafts(walletId: String, roundId: String) {
        UserDefaults.standard.removeObject(forKey: draftKey(walletId: walletId, roundId: roundId))
    }
}

// MARK: - Note Bundling

/// Result of value-aware note bundling on the Swift side.
struct BundleResult {
    let bundles: [[NoteInfo]]
    let eligibleWeight: UInt64
    let droppedCount: Int
}

extension Array where Element == NoteInfo {
    /// Value-aware bundling using greedy min-total assignment.
    ///
    /// Mirrors the Rust peer `chunk_notes` (see
    /// `zcash_voting/zcash_voting/src/types.rs` — function `chunk_notes`) for
    /// client-side use. The numbered steps in the body track that function
    /// one-to-one:
    /// 1. Sort notes by value DESC, then position ASC as tiebreaker
    /// 2. Fill bundles sequentially to capacity (5 notes each)
    /// 3. Drop bundles with total < ballotDivisor
    /// 4. Re-sort notes within each surviving bundle by position
    /// 5. Sort surviving bundles by total value DESC (min position as tiebreaker)
    func smartBundles() -> BundleResult {
        guard !isEmpty else {
            return BundleResult(bundles: [], eligibleWeight: 0, droppedCount: 0)
        }

        // Step 1: Sort by value DESC, then position ASC
        let sorted = self.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.position < rhs.position
        }

        // Step 2: Fill bundles sequentially to capacity (5 notes each)
        var bundleNotes: [[NoteInfo]] = []
        var bundleTotals: [UInt64] = []

        for note in sorted {
            if bundleNotes.isEmpty || (bundleNotes.last?.count ?? 0) >= 5 {
                bundleNotes.append([])
                bundleTotals.append(0)
            }
            let last = bundleNotes.count - 1
            bundleTotals[last] += note.value
            bundleNotes[last].append(note)
        }

        // Step 3: Drop bundles with total < ballotDivisor
        let numBundles = bundleNotes.count
        var surviving: [(total: UInt64, notes: [NoteInfo])] = []
        var eligibleWeight: UInt64 = 0
        var survivingNoteCount = 0

        for i in 0..<numBundles where bundleTotals[i] >= ballotDivisor {
            surviving.append((bundleTotals[i], bundleNotes[i]))
            eligibleWeight += quantizeWeight(bundleTotals[i])
            survivingNoteCount += bundleNotes[i].count
        }
        let droppedCount = count - survivingNoteCount

        // Step 5: Re-sort notes within each surviving bundle by position
        for i in 0..<surviving.count {
            surviving[i].notes.sort { $0.position < $1.position }
        }

        // Step 6: Sort surviving bundles by total value DESC (min position as tiebreaker).
        // This ensures bundle 0 is always the most valuable, enabling users to skip
        // low-value trailing bundles during Keystone signing.
        surviving.sort { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return (lhs.notes.first?.position ?? .max) < (rhs.notes.first?.position ?? .max)
        }

        return BundleResult(bundles: surviving.map(\.notes), eligibleWeight: eligibleWeight, droppedCount: droppedCount)
    }
}

/// Convert hex string to Data (used for share confirmation polling and API parsing).
func votingDataFromHex(_ hex: String) -> Data {
    var data = Data()
    var idx = hex.startIndex
    while idx < hex.endIndex {
        let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        if let byte = UInt8(hex[idx..<next], radix: 16) {
            data.append(byte)
        }
        idx = next
    }
    return data
}

// MARK: - Skip Bundles Alert

extension AlertState where Action == Voting.Action {
    static func confirmSkip(lockedIn: String, givingUp: String) -> AlertState {
        AlertState {
            TextState(String(localizable: .coinVoteDelegationSigningSkipAlertTitle))
        } actions: {
            ButtonState(role: .destructive, action: .skipRemainingKeystoneBundlesConfirmed) {
                TextState(String(localizable: .coinVoteDelegationSigningSkipAlertPrimary))
            }
            ButtonState(role: .cancel, action: .skipBundlesAlert(.dismiss)) {
                TextState(String(localizable: .coinVoteDelegationSigningSkipAlertCancel))
            }
        } message: {
            TextState(String(localizable: .coinVoteDelegationSigningSkipAlertMessage(lockedIn, givingUp)))
        }
    }
}
