//
//  AutoServerSelectionLiveKey.swift
//  Zashi
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension AutoServerSelectionClient: DependencyKey {
    static let liveValue = AutoServerSelectionClient(
        findBestServer: {
            await AutoServerSelectionClient.bestAutomaticCandidate()
        },
        applySwitch: { candidate in
            @Dependency(\.migrationManager) var migrationManager
            @Dependency(\.userStoredPreferences) var userStoredPreferences
            @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
            @Dependency(\.sdkSynchronizer) var sdkSynchronizer
            @Dependency(\.transactionGuard) var transactionGuard

            // Re-validate: the user may have switched to Manual, or changed servers
            // manually, while the benchmark ran or the candidate sat deferred.
            guard userStoredPreferences.automaticServerSelection() == true else { return false }

            let current = zcashSDKEnvironment.endpoint()
            guard candidate.host != current.host || candidate.port != current.port else { return false }

            // N4 again, deliberately: the pending-candidate path can apply MINUTES after the
            // benchmark ran, by which time a snapshot may have appeared or changed. A now-stale
            // cross-provider candidate has to be dropped here, not applied.
            let snapshots = migrationManager.activeNetworkSnapshots()
            guard MigrationServerPinning.isCandidateAllowed(host: candidate.host, activeSnapshots: snapshots) else {
                LoggerProxy.event("[AutoServerSelection] Switch skipped: candidate no longer allowed by migration pinning")
                return false
            }

            do {
                let didSwitch = try await transactionGuard.switchIfIdle {
                    try await withTimeout(serverSwitchTimeout) {
                        try await sdkSynchronizer.switchToEndpoint(candidate)
                    }
                }
                guard didSwitch else {
                    LoggerProxy.event("[AutoServerSelection] Switch skipped: transaction guard busy")
                    return false
                }

                try userStoredPreferences.setServer(candidate.serverConfig(isCustom: false))
                return true
            } catch {
                LoggerProxy.error("[AutoServerSelection] Failed to switch endpoint: \(error)")
                return false
            }
        },
        rebuildAfterStall: {
            @Dependency(\.userStoredPreferences) var userStoredPreferences
            @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
            @Dependency(\.sdkSynchronizer) var sdkSynchronizer
            @Dependency(\.transactionGuard) var transactionGuard

            let current = zcashSDKEnvironment.endpoint()
            // Unlike `applySwitch`'s candidate (which can be minutes stale by the time it applies),
            // this benchmark runs synchronously right here -- a fresh read every time, never deferred.
            // Automatic mode off, no qualifying candidate, or migration pinning excluding every one
            // all fall back to the SAME endpoint that's already configured: restarting there is still
            // useful when recovery gave up with no engine handle left behind.
            let candidate = await AutoServerSelectionClient.bestAutomaticCandidate() ?? current

            do {
                let started = try await transactionGuard.switchIfIdle {
                    try await withTimeout(serverSwitchTimeout) {
                        try await sdkSynchronizer.restartSync(candidate)
                    }
                }
                guard started else {
                    LoggerProxy.event("[AutoServerSelection] Terminal stall rebuild skipped: transaction guard busy")
                    return false
                }

                if candidate.host != current.host || candidate.port != current.port {
                    try userStoredPreferences.setServer(candidate.serverConfig(isCustom: false))
                }
                return true
            } catch {
                LoggerProxy.error("[AutoServerSelection] Terminal stall rebuild failed: \(error)")
                return false
            }
        }
    )
}

extension AutoServerSelectionClient {
    /// Shared by `findBestServer` and `rebuildAfterStall`: benchmarks the known endpoints when
    /// Automatic mode is enabled and asks the SDK whether switching is worth it
    /// (`evaluateServerSwitch`), filtered to whatever migration pinning currently allows. Returns
    /// nil when Automatic is off, migration pinning leaves no candidates, or staying on the current
    /// server is the right call.
    static func bestAutomaticCandidate() async -> LightWalletEndpoint? {
        @Dependency(\.migrationManager) var migrationManager
        @Dependency(\.userStoredPreferences) var userStoredPreferences
        @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
        @Dependency(\.sdkSynchronizer) var sdkSynchronizer

        guard userStoredPreferences.automaticServerSelection() == true else { return nil }

        let network = zcashSDKEnvironment.network().networkType
        let allEndpoints = ZcashSDKEnvironment.endpoints(for: network)

        // N4: while ANY account has an active migration network snapshot, auto-selection stays
        // within the snapshotted sync-provider family — never propose a switch that would drift
        // the wallet away from an in-flight run's deliberately-separated broadcast provider. No
        // active snapshots means no filtering, byte-identical to the pre-migration behaviour.
        let snapshots = migrationManager.activeNetworkSnapshots()
        let candidates = allEndpoints.filter {
            MigrationServerPinning.isCandidateAllowed(host: $0.host, activeSnapshots: snapshots)
        }
        guard !candidates.isEmpty else {
            if !snapshots.isEmpty {
                LoggerProxy.event("[AutoServerSelection] Skipped: migration pinning left no candidates")
            }
            return nil
        }

        // The switch decision — benchmark plus hysteresis — lives in the SDK. nil means the
        // improvement was not worth a synchronizer teardown (or nothing healthier exists).
        return await sdkSynchronizer.evaluateServerSwitch(
            zcashSDKEnvironment.endpoint(),
            candidates,
            AutoServerSelectionConstants.evaluationTimeoutSeconds,
            AutoServerSelectionConstants.blocksToDownload,
            network
        )
    }
}
