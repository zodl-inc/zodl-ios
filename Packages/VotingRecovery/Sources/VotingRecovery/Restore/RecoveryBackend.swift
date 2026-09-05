import Foundation
@preconcurrency import ZcashLightClientKit

/// One bundle to restore, in the escrow's own terms.
struct RecoveredDelegationBundleInput: Equatable, Sendable {
    let bundleIndex: UInt32
    /// Bundle weight in zatoshi.
    let totalNoteValue: UInt64
    /// The 32-byte VAN blinding factor.
    let vanCommRand: Data
    /// The 32-byte VAN commitment the recovered row carried. The SDK refuses
    /// a bundle whose blinding and weight do not open it.
    let van: Data
    /// Lowercase hex SHA-256 of the signed delegation transaction.
    let delegationTxHash: String
}

/// Inputs for restoring a carved delegation. Carries the hotkey secret and
/// the blinding factors, so it is deliberately not printable.
struct RecoveredDelegationImportRequest: Sendable, Undescribable {
    let roundParams: RoundParameters
    /// Rust network id, needed to derive the hotkey from its stored secret.
    let networkId: UInt32
    let voteChainId: String
    let hotkeyStoredSecret: Data
    let bundles: [RecoveredDelegationBundleInput]
    let sessionJson: String?
}

enum RecoveredDelegationRestoreOutcome: Equatable, Sendable {
    case restored
    case alreadyRestored
}

/// The two SDK calls the restore makes, over the app's open voting database.
/// The app supplies them through `VotingRecovery.configure`; tests build one
/// over a temporary backend with `live(backend:)`.
struct RecoveryBackend: Sendable {
    /// The VAN commitment a hotkey, round, weight and blinding open, as the
    /// SDK recomputes it before a restore clears anything.
    var vanCommitment: @Sendable (
        _ hotkeyStoredSecret: Data,
        _ networkId: UInt32,
        _ roundId: String,
        _ totalNoteValue: UInt64,
        _ vanCommRand: Data
    ) throws -> Data

    /// The SDK's guarded restore. It refuses unless the round holds nothing
    /// the wallet could still use, then clears it and imports the package,
    /// recomputing every VAN from the wallet's hotkey first.
    var restore: @Sendable (_ request: RecoveredDelegationImportRequest) async throws -> RecoveredDelegationRestoreOutcome

    /// Over a backend the app opened. `didRestore` runs after a round was
    /// cleared and imported, so the app can republish what it shows.
    static func live(
        backend: @escaping @Sendable () async throws -> VotingRustBackend,
        didRestore: @escaping @Sendable (_ roundId: String) async -> Void = { _ in }
    ) -> RecoveryBackend {
        RecoveryBackend(
            vanCommitment: { hotkeyStoredSecret, networkId, roundId, totalNoteValue, vanCommRand in
                let hotkey = try VotingRustBackend.hotkey(
                    fromStoredSecret: [UInt8](hotkeyStoredSecret),
                    networkId: networkId
                )
                return try Data(
                    VotingRustBackend.vanCommitment(
                        hotkey: hotkey,
                        networkId: networkId,
                        roundId: roundId,
                        totalNoteValue: totalNoteValue,
                        vanCommRand: [UInt8](vanCommRand)
                    )
                )
            },
            restore: { request in
                let backend = try await backend()
                let roundIdHex = request.roundParams.voteRoundId.hexEncoded
                // The SDK wants the semantic hotkey, not bare secret bytes; the
                // address it derives is what every VAN is recomputed from.
                let hotkey = try VotingRustBackend.hotkey(
                    fromStoredSecret: [UInt8](request.hotkeyStoredSecret),
                    networkId: request.networkId
                )
                let result = try backend.restoreRecoveredDelegation(
                    RecoveredDelegationRestoreRequest(
                        roundId: roundIdHex,
                        snapshotHeight: request.roundParams.snapshotHeight,
                        eaPublicKey: [UInt8](request.roundParams.eaPK),
                        ncRoot: [UInt8](request.roundParams.ncRoot),
                        nullifierImtRoot: [UInt8](request.roundParams.nullifierIMTRoot),
                        voteChainId: request.voteChainId,
                        hotkey: hotkey,
                        bundles: request.bundles.map {
                            RecoveredDelegationBundle(
                                bundleIndex: $0.bundleIndex,
                                totalNoteValue: $0.totalNoteValue,
                                vanCommRand: [UInt8]($0.vanCommRand),
                                van: [UInt8]($0.van),
                                delegationTxHash: $0.delegationTxHash
                            )
                        },
                        sessionJson: request.sessionJson
                    )
                )
                switch result {
                case .restored:
                    await didRestore(roundIdHex)
                    return .restored
                case .alreadyRestored:
                    return .alreadyRestored
                }
            }
        )
    }
}
