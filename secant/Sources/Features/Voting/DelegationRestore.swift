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

    /// The bundles a complete package needs, or nil when the escrow cannot
    /// supply one.
    ///
    /// Complete means: every entry was carved (`.recovered`), the indices run
    /// from 0 with no gap, every entry has a distinct lowercase-hex transaction
    /// hash, every weight is at least one ballot, and when the caller knows
    /// the round's bundle count, the package has exactly that many.
    static func package(
        from entries: [DelegationEscrowEntry],
        expectedBundleCount: UInt32?
    ) -> [RecoveredDelegationBundleInput]? {
        let recovered = entries
            .filter { $0.source == .recovered }
            .sorted { $0.bundleIndex < $1.bundleIndex }
        guard !recovered.isEmpty else { return nil }
        guard recovered.enumerated().allSatisfy({ $0.element.bundleIndex == UInt32($0.offset) }) else {
            return nil
        }
        if let expectedBundleCount, recovered.count != Int(expectedBundleCount) {
            return nil
        }

        var bundles: [RecoveredDelegationBundleInput] = []
        var hashes: Set<String> = []
        for entry in recovered {
            guard let hash = entry.delegationTxHash,
                  isLowercaseHexHash(hash),
                  hashes.insert(hash).inserted,
                  entry.vanCommRand.count == 32,
                  entry.totalNoteValue >= ballotDivisor
            else {
                return nil
            }
            bundles.append(
                RecoveredDelegationBundleInput(
                    bundleIndex: entry.bundleIndex,
                    totalNoteValue: entry.totalNoteValue,
                    vanCommRand: entry.vanCommRand,
                    delegationTxHash: hash
                )
            )
        }
        return bundles
    }

    /// 64 lowercase hex characters, the form the capability codec accepts.
    private static func isLowercaseHexHash(_ hash: String) -> Bool {
        let bytes = Array(hash.utf8)
        return bytes.count == 64
            && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
#endif
