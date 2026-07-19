//
//  AutoServerSelectionLiveKey.swift
//  Zashi
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension AutoServerSelectionClient: DependencyKey {
    static let liveValue = AutoServerSelectionClient(
        findBestServer: {
            @Dependency(\.userStoredPreferences) var userStoredPreferences
            @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
            @Dependency(\.sdkSynchronizer) var sdkSynchronizer
            @Dependency(\.migrationManager) var migrationManager

            guard userStoredPreferences.automaticServerSelection() == true else { return nil }

            let network = zcashSDKEnvironment.network().networkType
            let allEndpoints = ZcashSDKEnvironment.endpoints(for: network)

            // MOB-1496 (W4): while any account has an active migration network snapshot, stay
            // within the snapshotted sync-provider family(ies) — never propose a switch that would
            // drift auto-selection away from an in-flight run's separated broadcast provider. No
            // active snapshots -> unfiltered, byte-identical to pre-W4 behavior.
            let snapshots = migrationManager.activeNetworkSnapshots()
            let endpoints = allEndpoints.filter { isCandidateAllowedByMigrationPinning(host: $0.host, activeSnapshots: snapshots) }
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
            @Dependency(\.userStoredPreferences) var userStoredPreferences
            @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
            @Dependency(\.sdkSynchronizer) var sdkSynchronizer
            @Dependency(\.transactionGuard) var transactionGuard
            @Dependency(\.migrationManager) var migrationManager

            // Re-validate: the user may have switched to Manual, or changed servers
            // manually, while the benchmark ran or the candidate sat deferred.
            guard userStoredPreferences.automaticServerSelection() == true else { return false }

            let current = zcashSDKEnvironment.endpoint()
            guard candidate.host != current.host || candidate.port != current.port else { return false }

            // MOB-1496 (W4): re-validate pinning too — the pending-candidate path can apply minutes
            // later (Root's `pendingServerCandidate` gate), after a snapshot appeared or changed
            // since the candidate was benchmarked; a now-stale cross-provider candidate must be
            // dropped here, not applied.
            let snapshots = migrationManager.activeNetworkSnapshots()
            guard isCandidateAllowedByMigrationPinning(host: candidate.host, activeSnapshots: snapshots) else {
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

/// MOB-1496 (W4): the automatic-selection pinning predicate — shared by `findBestServer`'s
/// candidate filter and `applySwitch`'s re-validation. `true` when NO account has an active
/// migration network snapshot (unfiltered — byte-identical to pre-W4 behavior), or when `host`'s
/// classified provider is a member of the snapshotted SYNC providers (rotation within an active
/// run's own family stays allowed). That single check already keeps out any provider that is ONLY
/// some snapshot's broadcast provider, with no separate exclusion clause needed: the custom/testnet
/// same-server case (sync == broadcast) stays allowed because that provider IS a sync provider too.
/// (W7 review: an earlier, separate broadcast-exclusion `guard` here was provably dead — it could
/// never fail once the sync-provider check above had already passed — and was removed.)
private func isCandidateAllowedByMigrationPinning(host: String, activeSnapshots: [MigrationNetworkSnapshot]) -> Bool {
    guard !activeSnapshots.isEmpty else { return true }

    let syncProviders = Set(activeSnapshots.map { $0.syncProvider })
    let provider = ServerProvider.classify(host: host)

    guard syncProviders.contains(provider) else { return false }
    return true
}
