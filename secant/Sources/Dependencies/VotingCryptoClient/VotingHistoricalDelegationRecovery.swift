#if VOTING_ENABLED
import Foundation
@preconcurrency import ZcashLightClientKit

/// Joins the preserved database byte scanner to the SDK's validating restore
/// seam. This exists only for the small set of pre-3.10.2 stranded rounds.
enum VotingHistoricalDelegationRecovery {
    /// Build a secret-bearing SDK request only when the preserved files yield
    /// one complete and unambiguous candidate for every current bundle.
    static func prepareRequest(
        _ request: HistoricalVotingDelegationRecoveryRequest
    ) throws -> VotingForensicDelegationRecoveryRequest? {
        guard request.expectedBundleCount > 0,
              request.roundParams.voteRoundId.hexString == request.roundId
        else {
            return nil
        }

        let directory = try VotingDatabaseSnapshot.recoveryDirectory()
        let databaseURL = directory.appendingPathComponent(VotingDatabaseSnapshot.databaseName)
        guard VotingDatabaseSnapshot.holdsData(at: databaseURL) else { return nil }

        // Discovery uses only leaves from a snapshot whose advertised root the
        // Rust crate has recomputed. The restore call fetches and verifies the
        // tree again so these discovery results never authorize a DB write.
        let snapshot = try VotingRustBackend.verifiedVoteTreeSnapshot(
            roundId: request.roundId,
            nodeUrl: request.nodeURL
        )
        let targets = Set(snapshot.leaves.map { Data($0.commitment) })
        let walURL = directory.appendingPathComponent("\(VotingDatabaseSnapshot.databaseName)-wal")
        let reports = try VotingDatabaseRecovery.recover(
            databaseURL: databaseURL,
            walURL: walURL,
            vanCmxTargets: targets,
            roundId: request.roundId,
            walletId: request.walletId
        )
        guard let bundles = completeBatch(
            reports: reports,
            snapshot: snapshot,
            expectedBundleCount: request.expectedBundleCount
        ) else {
            return nil
        }

        return VotingForensicDelegationRecoveryRequest(
            expectedRoundParams: VotingForensicRoundParameters(
                voteRoundId: request.roundId,
                snapshotHeight: request.roundParams.snapshotHeight,
                eaPk: [UInt8](request.roundParams.eaPK),
                ncRoot: [UInt8](request.roundParams.ncRoot),
                nullifierImtRoot: [UInt8](request.roundParams.nullifierIMTRoot)
            ),
            nodeUrl: request.nodeURL,
            hotkeyStoredSecret: [UInt8](request.hotkeyStoredSecret),
            bundles: bundles
        )
    }

    /// Collapse duplicate provenance, but never collapse conflicting recovery
    /// material. Any ambiguity or missing bundle fails closed without a write.
    static func completeBatch(
        reports: [VotingDatabaseRecovery.Report],
        snapshot: VotingVerifiedVoteTreeSnapshot,
        expectedBundleCount: UInt32
    ) -> [VotingForensicDelegationBundle]? {
        guard expectedBundleCount > 0 else { return nil }

        let leavesByCommitment = Dictionary(grouping: snapshot.leaves) {
            Data($0.commitment)
        }
        var materialsByIndex: [UInt32: Set<Material>] = [:]
        var transactionHashes: [Material: Set<String>] = [:]

        for report in reports {
            // A VAN must occur exactly once in the validated public tree. The
            // SDK repeats this check against a fresh tree before writing.
            guard let leaves = leavesByCommitment[report.vanCmx], leaves.count == 1,
                  let leaf = leaves.first
            else {
                continue
            }

            for candidate in report.candidates {
                guard candidate.bundleIndex < expectedBundleCount,
                      let addressIndex = candidate.addressIndex
                else {
                    return nil
                }
                let material = Material(
                    bundleIndex: candidate.bundleIndex,
                    totalNoteValue: candidate.totalNoteValue,
                    addressIndex: addressIndex,
                    vanCommRand: candidate.vanCommRand,
                    vanCommitment: candidate.vanCmx,
                    vanLeafPosition: leaf.position
                )
                materialsByIndex[candidate.bundleIndex, default: []].insert(material)
                if let hash = candidate.delegationTxHash {
                    transactionHashes[material, default: []].insert(hash)
                }
            }
        }

        var result: [VotingForensicDelegationBundle] = []
        for bundleIndex in 0..<expectedBundleCount {
            guard let materials = materialsByIndex[bundleIndex],
                  materials.count == 1,
                  let material = materials.first
            else {
                return nil
            }
            let hashes = transactionHashes[material] ?? []
            guard hashes.count <= 1 else { return nil }
            result.append(material.sdkBundle(delegationTxHash: hashes.first))
        }
        return result
    }

    /// Only the fields consumed by the validating Rust API participate in
    /// ambiguity detection. Scanner provenance may legitimately differ.
    private struct Material: Hashable {
        let bundleIndex: UInt32
        let totalNoteValue: UInt64
        let addressIndex: UInt32
        let vanCommRand: Data
        let vanCommitment: Data
        let vanLeafPosition: UInt32

        func sdkBundle(delegationTxHash: String?) -> VotingForensicDelegationBundle {
            VotingForensicDelegationBundle(
                bundleIndex: bundleIndex,
                totalNoteValue: totalNoteValue,
                addressIndex: addressIndex,
                vanCommRand: [UInt8](vanCommRand),
                vanCommitment: [UInt8](vanCommitment),
                vanLeafPosition: vanLeafPosition,
                delegationTxHash: delegationTxHash
            )
        }
    }
}
#endif
