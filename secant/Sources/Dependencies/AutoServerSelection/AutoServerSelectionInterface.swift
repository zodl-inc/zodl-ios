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
    /// The bounded way back to a running sync once the SDK's own stall recovery has given up.
    /// Benchmarks a fresh candidate (`findBestServer()`'s underlying logic) BEFORE taking the
    /// transaction guard, so waiting for it never holds other work back -- but the decision of what
    /// to restart at is made fresh, INSIDE the guard the manual Save path in `ServerSetupStore` also
    /// uses (`switchWaiting`): Automatic/Manual mode, the currently configured endpoint, and
    /// migration pinning are all re-read at that point, not carried over from before the wait. A
    /// manual switch or a pinning change that lands while the rebuild is parked on the guard is
    /// picked up and wins over the (possibly by-then-stale) benchmark; the benchmarked candidate is
    /// used only when Automatic mode is still on and migration pinning still allows it, otherwise the
    /// freshly-read current endpoint is used -- restarting there is still useful when recovery gave
    /// up with no engine handle left. Uses `switchWaiting` via `SDKSynchronizerClient.restartSync`,
    /// not `applySwitch`'s `switchIfIdle`: a give-up already spent one of a small per-foreground
    /// budget (`Root.State.maxTerminalStallRebuildsPerForeground`) on this attempt, and the SDK only
    /// emits `gaveUp: true` once per handle, so skipping the rebuild outright when a broadcast merely
    /// happens to be in flight would waste that budget credit for nothing -- waiting instead runs the
    /// rebuild once the broadcast clears. Persists the server preference INSIDE the guard, same
    /// discipline as `ServerSetupStore.applyServerSwitch`, only when Automatic mode is (still) on and
    /// the target actually differs from the freshly-read current endpoint. Returns whether a pass was
    /// actually started; never throws, failures are logged.
    var rebuildAfterStall: @Sendable () async -> Bool = { false }
}

enum AutoServerSelectionConstants {
    // Lightweight startup/foreground benchmark: cheap checks, short fetch.
    static let evaluationTimeoutSeconds = 5.0
    static let blocksToDownload: UInt64 = 1
    /// A deferred switch candidate older than this is dropped instead of applied.
    static let pendingCandidateTTL: TimeInterval = 15 * 60
}
