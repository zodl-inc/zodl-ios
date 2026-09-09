import Dependencies
import DependenciesMacros
import Foundation

extension DependencyValues {
    public var delegationRestore: DelegationRestoreClient {
        get { self[DelegationRestoreClient.self] }
        set { self[DelegationRestoreClient.self] = newValue }
    }
}

/// What the voting flow asks of recovery: put a carved delegation back before
/// a poll is entered, remember a leaf the chain refused, and say whether the
/// escrow shows that anything was lost.
@DependencyClient
public struct DelegationRestoreClient: Sendable {
    /// Restores the round from the escrow when it holds a restorable
    /// delegation. Reads the escrow first, so an unaffected round costs one
    /// file read and no SDK call.
    public var restoreIfNeeded: @Sendable (
        _ roundId: String,
        _ round: RoundParameters,
        _ networkId: UInt32,
        _ hotkeyStoredSecret: Data?
    ) async -> DelegationRestore.Outcome = { _, _, _, _ in .notApplicable(reason: "unimplemented") }

    /// Marks the candidate the chain refused at tree sync, so the next
    /// restore offers the next-best one. Returns whether `error` was a leaf
    /// mismatch at all.
    public var noteChainRefusal: @Sendable (
        _ roundId: String,
        _ error: Error,
        _ hotkeyStoredSecret: Data,
        _ networkId: UInt32
    ) async -> Bool = { _, _, _, _ in false }

    /// Whether the escrow holds more than one distinct blinding for some
    /// bundle of the round: the evidence that it was cleared and rebuilt.
    public var holdsRecoveredSecrets: @Sendable (_ roundId: String) async -> Bool = { _ in false }
}

extension DelegationRestoreClient: DependencyKey {
    public static var liveValue: Self { live(backend: VotingRecovery.backend()) }

    static func live(backend: RecoveryBackend) -> Self {
        @Dependency(\.delegationEscrow) var delegationEscrow
        return Self(
            restoreIfNeeded: { roundId, round, networkId, hotkeyStoredSecret in
                let entries = (try? await delegationEscrow.entries(roundId)) ?? []
                guard entries.contains(where: { $0.source == .recovered }) else {
                    return .notApplicable(reason: "nothing recovered for this round")
                }
                let outcome = await DelegationRestore.restoreIfNeeded(
                    roundId: roundId,
                    roundParams: round,
                    networkId: networkId,
                    hotkeyStoredSecret: hotkeyStoredSecret,
                    escrowEntries: entries,
                    crypto: backend
                )
                Log.info("[poll-restore] round=\(roundId) outcome=\(outcome)")
                return outcome
            },
            noteChainRefusal: { roundId, error, hotkeyStoredSecret, networkId in
                await DelegationRestore.rejectRestoredCandidates(
                    roundId: roundId,
                    error: error,
                    escrow: delegationEscrow,
                    opens: DelegationRestore.opens(
                        hotkeyStoredSecret: hotkeyStoredSecret,
                        networkId: networkId,
                        roundId: roundId,
                        crypto: backend
                    )
                )
            },
            holdsRecoveredSecrets: { roundId in
                // Every carved row is escrowed, the live one included, so
                // presence alone is not evidence that anything was lost.
                let entries = (try? await delegationEscrow.entries(roundId)) ?? []
                return Dictionary(grouping: entries.filter { $0.source == .recovered }, by: \.bundleIndex)
                    .values.contains { Set($0.map(\.vanCommRand)).count > 1 }
            }
        )
    }
}
