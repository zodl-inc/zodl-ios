import ConcurrencyExtras
import Dependencies
import Foundation
@preconcurrency import ZcashLightClientKit

/// Recovery of delegations an earlier build wiped: the pre-open snapshot of
/// the voting database, the launch-time carve of every preserved copy, the
/// escrow that keeps what the carve found, and the guarded restore that puts
/// it back before a poll is entered.
///
/// The whole mechanism lives in this package. The app reaches it through the
/// seams below and the two dependency clients, each call site marked
/// `VotingRecovery`, so that deleting the package and those lines removes
/// it. See the package README for the procedure.
public enum VotingRecovery {
    /// Cancel id of the launch-time recovery effect. A wallet reset cancels
    /// it before wiping.
    public enum CancelID: Hashable, Sendable {
        case launch
    }

    private static let registeredLogger = LockIsolated<@Sendable () -> ZcashLightClientKit.Logger?>({ nil })
    private static let registeredBackend = LockIsolated<RecoveryBackend?>(nil)

    /// Hands the module what it cannot own: the app's logger and its open
    /// voting database. Call once, where the database actor is created.
    /// `didRestore` runs after a round was cleared and imported, so the app
    /// can republish what it shows for that round.
    public static func configure(
        logger: @escaping @Sendable () -> ZcashLightClientKit.Logger?,
        backend: @escaping @Sendable () async throws -> VotingRustBackend,
        didRestore: @escaping @Sendable (_ roundId: String) async -> Void = { _ in }
    ) {
        registeredLogger.setValue(logger)
        registeredBackend.setValue(.live(backend: backend, didRestore: didRestore))
    }

    /// Copies the voting database and its log aside before anything opens
    /// them. Opening checkpoints and unlinks the write-ahead log, and the log
    /// is the only place a cleared round's original secrets still exist.
    public static func preserve(databasePath: String) {
        VotingDatabaseSnapshot.capture(databasePath: databasePath)
    }

    /// Escrows a delegation's blinding factor at the one moment the app holds
    /// it, while the PCZT is built. A failed write is logged, never thrown:
    /// it must not abort a delegation the user has already paid for. The
    /// hash is not known yet, so a live capture is never a complete
    /// capability record; the carved path supplies that.
    public static func captureLiveDelegation(
        roundId: String,
        bundleIndex: UInt32,
        vanCommRand: Data,
        van: Data,
        totalNoteValue: UInt64
    ) async {
        @Dependency(\.delegationEscrow) var delegationEscrow
        do {
            try await delegationEscrow.record(
                DelegationEscrowEntry(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    vanCommRand: vanCommRand,
                    van: van,
                    totalNoteValue: totalNoteValue,
                    delegationTxHash: nil,
                    source: .liveCapture,
                    createdAt: Date()
                )
            )
        } catch {
            Log.error("Delegation escrow write failed for round \(roundId) bundle \(bundleIndex): \(error)")
        }
    }

    /// The wallet-reset half. Removes the preserved copies and the escrow,
    /// and makes any launch-time recovery still in flight refuse to write.
    /// Synchronous, because reset runs in a plain reducer case.
    public static func wipe(inDocuments documents: URL) {
        VotingDatabaseSnapshot.reset()
        DelegationEscrowFile.invalidate(inDocuments: documents)
    }

    static func logger() -> ZcashLightClientKit.Logger? {
        registeredLogger.value()
    }

    /// The backend `configure` registered. Before `configure`, one that fails
    /// every call, so a restore reports `.failed` rather than trapping.
    static func backend() -> RecoveryBackend {
        registeredBackend.value ?? RecoveryBackend(
            vanCommitment: { _, _, _, _, _ in throw NotConfigured() },
            restore: { _ in throw NotConfigured() }
        )
    }

    struct NotConfigured: Error {}
}
