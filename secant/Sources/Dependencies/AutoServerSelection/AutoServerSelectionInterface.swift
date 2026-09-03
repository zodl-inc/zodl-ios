//
//  AutoServerSelectionInterface.swift
//  Zashi
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZODLSwiftWalletSDK

extension DependencyValues {
    var autoServerSelection: AutoServerSelectionClient {
        get { self[AutoServerSelectionClient.self] }
        set { self[AutoServerSelectionClient.self] = newValue }
    }
}

@DependencyClient
struct AutoServerSelectionClient {
    /// Benchmarks the known endpoints when Automatic mode is enabled and asks the SDK whether
    /// switching is worth it (`evaluateServerSwitch`): the SDK returns the endpoint to switch to
    /// only when it is meaningfully faster than the current one or the current one is unhealthy.
    /// Returns nil when Automatic is off, migration pinning leaves no candidates, or staying on
    /// the current server is the right call.
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
    /// A deferred switch candidate older than this is dropped instead of applied.
    static let pendingCandidateTTL: TimeInterval = 15 * 60
}
