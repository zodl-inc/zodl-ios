#if RECOVERY_VOTING_ENABLED
import Foundation

// MARK: - Several on-chain targets at once

extension VotingDatabaseRecovery {
    /// Recovers every exact on-chain target present in the files, scanning
    /// once for presence before the full decoder runs per target. Reports
    /// come back in target order.
    static func recover(
        databaseBytes: [UInt8],
        walBytes: [UInt8]? = nil,
        vanCmxTargets: Set<Data>,
        roundId: String,
        walletId: String? = nil
    ) throws -> [Report] {
        if let invalid = vanCmxTargets.first(where: { $0.count != 32 }) {
            throw RecoveryError.invalidVanCmxLength(invalid.count)
        }
        guard isCanonicalRoundId(roundId) else {
            throw RecoveryError.invalidRoundId
        }

        var present = targetsPresent(in: databaseBytes, targets: vanCmxTargets)
        if let walBytes {
            present.formUnion(targetsPresent(in: walBytes, targets: vanCmxTargets))
        }

        return try present
            .sorted { $0.lexicographicallyPrecedes($1) }
            .map { target in
                try recover(
                    databaseBytes: databaseBytes,
                    walBytes: walBytes,
                    vanCmx: target,
                    roundId: roundId,
                    walletId: walletId
                )
            }
    }

    static func recover(
        databaseURL: URL,
        walURL: URL? = nil,
        vanCmxTargets: Set<Data>,
        roundId: String,
        walletId: String? = nil
    ) throws -> [Report] {
        let database = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        let wal: Data?
        if let walURL, FileManager.default.fileExists(atPath: walURL.path) {
            wal = try Data(contentsOf: walURL, options: .mappedIfSafe)
        } else {
            wal = nil
        }
        return try recover(
            databaseBytes: [UInt8](database),
            walBytes: wal.map { [UInt8]($0) },
            vanCmxTargets: vanCmxTargets,
            roundId: roundId,
            walletId: walletId
        )
    }

    /// Which 32-byte targets occur anywhere in `bytes`, keyed by a four-byte
    /// prefix so a large tree costs one pass.
    private static func targetsPresent(in bytes: [UInt8], targets: Set<Data>) -> Set<Data> {
        guard bytes.count >= 32, !targets.isEmpty else { return [] }
        let grouped = Dictionary(grouping: targets.map { ([UInt8]($0), $0) }) { targetPrefix($0.0) }
        var found: Set<Data> = []
        for offset in 0...(bytes.count - 32) {
            guard let candidates = grouped[targetPrefix(bytes, at: offset)] else { continue }
            for (targetBytes, target) in candidates
            where !found.contains(target) && bytes[offset..<(offset + 32)].elementsEqual(targetBytes) {
                found.insert(target)
            }
            if found.count == targets.count { break }
        }
        return found
    }

    private static func targetPrefix(_ bytes: [UInt8], at offset: Int = 0) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
#endif
