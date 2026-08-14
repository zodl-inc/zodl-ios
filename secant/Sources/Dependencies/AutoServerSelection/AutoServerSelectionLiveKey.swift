//
//  AutoServerSelectionLiveKey.swift
//  Zashi
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension AutoServerSelectionClient: DependencyKey {
    static let liveValue = AutoServerSelectionClient(
        findBestServer: {
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
            let endpoints = allEndpoints.filter {
                MigrationServerPinning.isCandidateAllowed(host: $0.host, activeSnapshots: snapshots)
            }
            guard !endpoints.isEmpty else {
                if !snapshots.isEmpty {
                    LoggerProxy.event("[AutoServerSelection] Skipped: migration pinning left no candidates")
                }
                return nil
            }

            let ranked = await sdkSynchronizer.evaluateBestOf(
                endpoints,
                AutoServerSelectionConstants.evaluationTimeoutSeconds,
                AutoServerSelectionConstants.blocksToDownload,
                AutoServerSelectionConstants.candidateCount,
                network
            )

            guard let best = ranked.first else { return nil }

            let current = zcashSDKEnvironment.endpoint()
            guard best.host != current.host || best.port != current.port else { return nil }

            return best
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
        }
    )
}
