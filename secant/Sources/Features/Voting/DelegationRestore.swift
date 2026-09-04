#if RECOVERY_VOTING_ENABLED
import Foundation

/// Puts a carved delegation back into the voting database, through the SDK's
/// guarded restore, so the poll can be voted on.
enum DelegationRestore {
    /// The vote chain identifier written into the package and handed to the
    /// import as the expected value. zcash_voting 3.0.0 compares the two to
    /// each other and to nothing else, so the one requirement is stability: a
    /// byte-identical re-import is a no-op, and a differing one is a conflict.
    static let voteChainId = "zcash-coinholder-polling"

    /// Zatoshi per ballot. A bundle below one ballot cannot be imported.
    static let ballotDivisor: UInt64 = 12_500_000

    enum Outcome: Equatable, Sendable {
        /// The escrow does not hold a complete recovered delegation, or the
        /// device has no hotkey to recompute the commitments with.
        case notApplicable(reason: String)
        /// The database already holds exactly this delegation.
        case alreadyRestored
        /// The round was cleared and the delegation imported.
        case restored(bundleCount: Int)
        /// The SDK's guards refused to clear the round. The reason names the
        /// guard and carries no secret.
        case refused(reason: String)
        /// The SDK reported a failure that is not a guard.
        case failed

        /// The marker every guard refusal from the SDK carries.
        static let refusalMarker = "nothing may be cleared"
    }

    /// Restores the round from the escrow when it holds a complete recovered
    /// delegation. Whether the database may be cleared is decided in the SDK,
    /// on the live rows, in the same call that clears; the app only decides
    /// whether there is anything worth asking about.
    static func restoreIfNeeded(
        roundId: String,
        roundParams: VotingRoundParams,
        networkId: UInt32,
        hotkeyStoredSecret: Data?,
        escrowEntries: [DelegationEscrowEntry],
        crypto: VotingCryptoClient
    ) async -> Outcome {
        guard let hotkeyStoredSecret else {
            return .notApplicable(reason: "no voting hotkey on this device")
        }
        // The same check the SDK makes before it clears anything, made here
        // per candidate so a damaged row image is passed over rather than
        // refusing the whole restore.
        let opens: (DelegationEscrowEntry) -> Bool = { entry in
            let recomputed = try? crypto.vanCommitment(
                hotkeyStoredSecret, networkId, roundId, entry.totalNoteValue, entry.vanCommRand
            )
            return recomputed == entry.van
        }
        guard let bundles = package(from: escrowEntries, opens: opens) else {
            return .notApplicable(reason: "escrow holds no restorable delegation")
        }

        do {
            let result = try await crypto.restoreRecoveredDelegation(
                RecoveredDelegationImportRequest(
                    roundParams: roundParams,
                    networkId: networkId,
                    voteChainId: voteChainId,
                    hotkeyStoredSecret: hotkeyStoredSecret,
                    bundles: bundles,
                    sessionJson: nil
                )
            )
            switch result {
            case .alreadyRestored:
                return .alreadyRestored
            case .restored:
                LoggerProxy.info("[poll-restore] round=\(roundId) restored \(bundles.count) bundle(s) from the escrow")
                return .restored(bundleCount: bundles.count)
            }
        } catch {
            // The crate's and the FFI's messages name conditions and counts,
            // never row contents.
            let description = error.localizedDescription
            if description.contains(Outcome.refusalMarker) {
                let reason = description.components(separatedBy: "failed: ").last ?? description
                LoggerProxy.info("[poll-restore] round=\(roundId) refused: \(reason)")
                return .refused(reason: reason)
            }
            LoggerProxy.error("[poll-restore] round=\(roundId) restore failed: \(description)")
            return .failed
        }
    }

    /// The longest run of bundles from index 0 the escrow can restore, or nil
    /// when it cannot restore any.
    ///
    /// Restorable means: the entry was carved (`.recovered`), its blinding and
    /// commitment are 32 bytes, its weight is at least one ballot, and it has
    /// a lowercase-hex transaction hash no earlier bundle shares. The run
    /// stops at the first index without such an entry: the SDK imports only a
    /// prefix, and each bundle votes on its own, so a lost trailing bundle
    /// costs its own voting power and nothing else.
    ///
    /// Where a bundle holds several candidates, the best-ranked one that
    /// `opens` its commitment and that the chain has not refused is offered.
    /// Nothing here decides which is the original; the chain does, and a
    /// refusal is recorded on the candidate.
    static func package(
        from entries: [DelegationEscrowEntry],
        opens: (DelegationEscrowEntry) -> Bool = { _ in true }
    ) -> [RecoveredDelegationBundleInput]? {
        let candidates = Dictionary(
            grouping: entries.filter { $0.source == .recovered && $0.rejectedAt == nil },
            by: \.bundleIndex
        )
        var bundles: [RecoveredDelegationBundleInput] = []
        var hashes: Set<String> = []
        var index: UInt32 = 0
        while let bundle = candidates[index]?
            .sorted(by: { $0.provenanceRank > $1.provenanceRank })
            .compactMap({ opens($0) ? restorable($0, excluding: hashes) : nil })
            .first {
            hashes.insert(bundle.delegationTxHash)
            bundles.append(bundle)
            index += 1
        }
        return bundles.isEmpty ? nil : bundles
    }

    /// The input one candidate yields, or nil when it cannot be imported.
    private static func restorable(
        _ entry: DelegationEscrowEntry,
        excluding hashes: Set<String>
    ) -> RecoveredDelegationBundleInput? {
        guard let hash = entry.delegationTxHash,
              isLowercaseHexHash(hash),
              !hashes.contains(hash),
              entry.vanCommRand.count == 32,
              entry.van.count == 32,
              entry.totalNoteValue >= ballotDivisor
        else {
            return nil
        }
        return RecoveredDelegationBundleInput(
            bundleIndex: entry.bundleIndex,
            totalNoteValue: entry.totalNoteValue,
            vanCommRand: entry.vanCommRand,
            van: entry.van,
            delegationTxHash: hash
        )
    }

    /// 64 lowercase hex characters, the form the capability codec accepts.
    private static func isLowercaseHexHash(_ hash: String) -> Bool {
        let bytes = Array(hash.utf8)
        return bytes.count == 64
            && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
#endif
