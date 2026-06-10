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

            guard userStoredPreferences.automaticServerSelection() == true else { return nil }

            let network = zcashSDKEnvironment.network().networkType
            let endpoints = ZcashSDKEnvironment.endpoints(for: network)

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

            // Re-validate: the user may have switched to Manual, or changed servers
            // manually, while the benchmark ran or the candidate sat deferred.
            guard userStoredPreferences.automaticServerSelection() == true else { return false }

            let current = zcashSDKEnvironment.endpoint()
            guard candidate.host != current.host || candidate.port != current.port else { return false }

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
