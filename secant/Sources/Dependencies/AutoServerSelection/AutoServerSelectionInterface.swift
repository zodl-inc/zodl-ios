//
//  AutoServerSelectionInterface.swift
//  Zashi
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var autoServerSelection: AutoServerSelectionClient {
        get { self[AutoServerSelectionClient.self] }
        set { self[AutoServerSelectionClient.self] = newValue }
    }
}

@DependencyClient
struct AutoServerSelectionClient {
    /// Benchmarks the known endpoints when Automatic mode is enabled. Returns the best
    /// endpoint when it differs from the current one; nil when Automatic is off, the
    /// benchmark produced nothing, or the best server is already the current one.
    var findBestServer: @Sendable () async -> LightWalletEndpoint? = { nil }
    /// Re-validates (Automatic still on, candidate still differs from current) and applies
    /// the switch under the transaction guard (`switchIfIdle` + timeout), then persists
    /// the new server. Returns true when the switch ran and the new server was persisted.
    /// Never throws; failures are logged.
    var applySwitch: @Sendable (LightWalletEndpoint) async -> Bool = { _ in false }
}

enum AutoServerSelectionConstants {
    // Lightweight startup/foreground benchmark: cheap checks, short fetch.
    static let evaluationTimeoutSeconds = 5.0
    static let blocksToDownload: UInt64 = 1
    static let candidateCount = 3
    /// A deferred switch candidate older than this is dropped instead of applied.
    static let pendingCandidateTTL: TimeInterval = 15 * 60
}
