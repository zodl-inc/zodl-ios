#if RECOVERY_VOTING_ENABLED
import Foundation

/// What a targeted scan against the round's on-chain commitments shows.
///
/// Available only once a root-validated leaf list can be fetched; until then
/// `leaves` is nil and the evidence is `.unavailable`. Wiring it in is one
/// argument at the diagnosis call site: `commitmentPresentButUndecodable`.
enum DelegationEvidence: Equatable, Sendable {
    case unavailable
    case nothingOnDevice
    /// A commitment the chain holds occurs in the preserved bytes, but no
    /// record around it decodes. The escrow has nothing; support may still
    /// recover it by hand from the preserved copy.
    case commitmentPresentButUndecodable
    case verified(bundleCount: Int)

    static func gather(
        roundId: String,
        leaves: [Data]?,
        sources: [DelegationRecoveryClient.Source]
    ) -> DelegationEvidence {
        guard let leaves, !leaves.isEmpty else { return .unavailable }
        var anyRawHit = false
        var verified: Set<UInt32> = []
        for source in sources {
            guard let reports = try? VotingDatabaseRecovery.recover(
                databaseURL: source.databaseURL,
                walURL: source.walURL,
                vanCmxTargets: Set(leaves),
                roundId: roundId
            ) else { continue }
            for report in reports {
                anyRawHit = anyRawHit || !report.rawTargetHits.isEmpty
                verified.formUnion(report.candidates.map(\.bundleIndex))
            }
        }
        if !verified.isEmpty { return .verified(bundleCount: verified.count) }
        return anyRawHit ? .commitmentPresentButUndecodable : .nothingOnDevice
    }
}
#endif
