//
//  AutoServerSelectionPinningTests.swift
//  zodlTests
//
//  Covers MOB-1496 (W4)'s auto-selection pinning: while any account has an active migration network
//  snapshot, `AutoServerSelectionLiveKey`'s automatic path (`findBestServer`/`applySwitch`) stays
//  within the snapshotted sync-provider family(ies) and never proposes/applies a candidate on a
//  snapshot's broadcast provider (unless that provider is also a snapshotted sync provider — the
//  custom/testnet same-server case). The user-facing ServerSetup "Recommended Servers" benchmark is
//  a SEPARATE code path (`ServerSetup.swift`'s own `evaluateServers`) and is NOT filtered — not
//  covered here. Companion to `AutoServerSelectionClientTests.swift` (XCTest, pre-existing); new
//  coverage here uses Swift Testing per house convention.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct AutoServerSelectionPinningTests {
    private func endpoint(_ host: String) -> LightWalletEndpoint {
        LightWalletEndpoint(address: host, port: 443, secure: true, streamingCallTimeoutInMillis: 0)
    }

    private func snapshot(syncHost: String, broadcastHost: String) -> MigrationNetworkSnapshot {
        MigrationNetworkSnapshot(
            useTor: false,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: syncHost, port: 443, secure: true),
            syncProvider: ServerProvider.classify(host: syncHost),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: broadcastHost, port: 443, secure: true),
            broadcastProvider: ServerProvider.classify(host: broadcastHost),
            takenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - findBestServer: candidate filtering

    @Test func findBestServerWithNoActiveSnapshotsIsUnfiltered() async {
        // Byte-identical to pre-W4 behavior: every built-in mainnet candidate stays eligible.
        let capturedCandidates = LockIsolated<[LightWalletEndpoint]>([])
        let result = await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { true }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { self.endpoint("zec.rocks") }
            $0.sdkSynchronizer.evaluateBestOf = { candidates, _, _, _, _ in
                capturedCandidates.setValue(candidates)
                return [self.endpoint("na.zec.rocks")]
            }
            $0.migrationManager.activeNetworkSnapshots = { [] }
        } operation: {
            await AutoServerSelectionClient.liveValue.findBestServer()
        }

        #expect(result?.host == "na.zec.rocks")
        #expect(Set(capturedCandidates.value.map(\.host)) == Set([
            "zec.rocks", "na.zec.rocks", "sa.zec.rocks", "eu.zec.rocks", "ap.zec.rocks",
            "us.zec.stardust.rest", "eu.zec.stardust.rest"
        ]))
    }

    @Test func findBestServerWithActiveZecRocksSyncSnapshotOffersOnlyZecRocksCandidates() async {
        let capturedCandidates = LockIsolated<[LightWalletEndpoint]>([])
        let activeSnapshot = snapshot(syncHost: "na.zec.rocks", broadcastHost: "us.zec.stardust.rest")

        let result = await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { true }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { self.endpoint("na.zec.rocks") }
            $0.sdkSynchronizer.evaluateBestOf = { candidates, _, _, _, _ in
                capturedCandidates.setValue(candidates)
                return [self.endpoint("eu.zec.rocks")]
            }
            $0.migrationManager.activeNetworkSnapshots = { [activeSnapshot] }
        } operation: {
            await AutoServerSelectionClient.liveValue.findBestServer()
        }

        #expect(result?.host == "eu.zec.rocks")
        // Only the zecRocks family is offered — the stardust family (incl. the snapshot's OWN
        // broadcast provider) never reaches the benchmark at all.
        #expect(Set(capturedCandidates.value.map(\.host)) == Set(["zec.rocks", "na.zec.rocks", "sa.zec.rocks", "eu.zec.rocks", "ap.zec.rocks"]))
    }

    @Test func findBestServerCandidateOnSnapshotsBroadcastProviderIsExcluded() async {
        // A candidate matching the snapshot's BROADCAST provider (stardust) must never be offered,
        // even though nothing else about it looks disqualifying.
        let capturedCandidates = LockIsolated<[LightWalletEndpoint]>([])
        let activeSnapshot = snapshot(syncHost: "na.zec.rocks", broadcastHost: "us.zec.stardust.rest")

        _ = await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { true }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { self.endpoint("na.zec.rocks") }
            $0.sdkSynchronizer.evaluateBestOf = { candidates, _, _, _, _ in
                capturedCandidates.setValue(candidates)
                return []
            }
            $0.migrationManager.activeNetworkSnapshots = { [activeSnapshot] }
        } operation: {
            await AutoServerSelectionClient.liveValue.findBestServer()
        }

        let candidateHosts = Set(capturedCandidates.value.map(\.host))
        #expect(!candidateHosts.contains("us.zec.stardust.rest"))
        #expect(!candidateHosts.contains("eu.zec.stardust.rest"))
    }

    @Test func findBestServerWithSyncEqualsBroadcastSnapshotStillAllowsThatProvider() async {
        // The custom/testnet same-server snapshot (sync == broadcast, both classify the SAME
        // provider) must not empty the candidate set for its own family.
        let capturedCandidates = LockIsolated<[LightWalletEndpoint]>([])
        let sameServerSnapshot = snapshot(syncHost: "testnet.zec.rocks", broadcastHost: "testnet.zec.rocks")

        let result = await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { true }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { self.endpoint("na.zec.rocks") }
            $0.sdkSynchronizer.evaluateBestOf = { candidates, _, _, _, _ in
                capturedCandidates.setValue(candidates)
                return [self.endpoint("eu.zec.rocks")]
            }
            $0.migrationManager.activeNetworkSnapshots = { [sameServerSnapshot] }
        } operation: {
            await AutoServerSelectionClient.liveValue.findBestServer()
        }

        // testnet.zec.rocks classifies `.zecRocks`, same family as na/eu.zec.rocks — the same-server
        // snapshot's sync==broadcast provider is a syncProvider, so its whole family stays allowed.
        #expect(result?.host == "eu.zec.rocks")
        #expect(!capturedCandidates.value.isEmpty)
    }

    @Test func findBestServerSkipsTheRoundEntirelyWhenPinningLeavesNoCandidates() async {
        // A custom-family sync snapshot: no BUILT-IN host ever classifies as that specific custom
        // host, so the whole benchmark candidate list is filtered to empty. Must skip (return nil),
        // never fall back to unfiltered.
        let evaluateBestOfCalls = LockIsolated<Int>(0)
        let customSnapshot = MigrationNetworkSnapshot(
            useTor: false,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: "myserver.example.com", port: 9067, secure: true),
            syncProvider: ServerProvider.custom(host: "myserver.example.com"),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: "myserver.example.com", port: 9067, secure: true),
            broadcastProvider: ServerProvider.custom(host: "myserver.example.com"),
            takenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let result = await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { true }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { self.endpoint("myserver.example.com") }
            $0.sdkSynchronizer.evaluateBestOf = { _, _, _, _, _ in
                evaluateBestOfCalls.withValue { $0 += 1 }
                return [self.endpoint("na.zec.rocks")]
            }
            $0.migrationManager.activeNetworkSnapshots = { [customSnapshot] }
        } operation: {
            await AutoServerSelectionClient.liveValue.findBestServer()
        }

        #expect(result == nil)
        #expect(evaluateBestOfCalls.value == 0, "the benchmark must never run once pinning empties the candidate set")
    }

    // MARK: - applySwitch: pending-candidate re-validation

    @Test func applySwitchAppliesACandidateStillAllowedByPinning() async {
        let switchedTo = LockIsolated<LightWalletEndpoint?>(nil)
        let activeSnapshot = snapshot(syncHost: "na.zec.rocks", broadcastHost: "us.zec.stardust.rest")

        let didSwitch = await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { true }
            $0.userStoredPreferences.setServer = { _ in }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { self.endpoint("na.zec.rocks") }
            $0.sdkSynchronizer.switchToEndpoint = { switchedTo.setValue($0) }
            $0.transactionGuard = TransactionGuardClient(acquire: {}, tryAcquire: { true }, release: {})
            $0.migrationManager.activeNetworkSnapshots = { [activeSnapshot] }
        } operation: {
            await AutoServerSelectionClient.liveValue.applySwitch(endpoint("eu.zec.rocks"))
        }

        #expect(didSwitch == true)
        #expect(switchedTo.value?.host == "eu.zec.rocks")
    }

    /// The candidate was benchmarked/deferred (`Root.State.pendingServerCandidate`) BEFORE a
    /// migration snapshot appeared; by the time `applySwitch` finally runs, the candidate's provider
    /// is no longer allowed. Must be dropped — not applied — and `switchToEndpoint` must never fire.
    @Test func applySwitchDropsAStaleCandidateThatPinningNoLongerAllows() async {
        let switchedTo = LockIsolated<LightWalletEndpoint?>(nil)
        let setServerCalls = LockIsolated<Int>(0)
        let activeSnapshot = snapshot(syncHost: "na.zec.rocks", broadcastHost: "us.zec.stardust.rest")

        let didSwitch = await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { true }
            $0.userStoredPreferences.setServer = { _ in setServerCalls.withValue { $0 += 1 } }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { self.endpoint("na.zec.rocks") }
            $0.sdkSynchronizer.switchToEndpoint = { switchedTo.setValue($0) }
            $0.transactionGuard = TransactionGuardClient(acquire: {}, tryAcquire: { true }, release: {})
            $0.migrationManager.activeNetworkSnapshots = { [activeSnapshot] }
        } operation: {
            // A stardust-family candidate — the snapshot's own broadcast provider, now disallowed.
            await AutoServerSelectionClient.liveValue.applySwitch(endpoint("eu.zec.stardust.rest"))
        }

        #expect(didSwitch == false)
        #expect(switchedTo.value == nil)
        #expect(setServerCalls.value == 0)
    }

    @Test func applySwitchAllowsACandidateOnTheSameServerSnapshotsSharedProvider() async {
        // sync == broadcast snapshot: candidates within that SAME family remain applicable.
        let switchedTo = LockIsolated<LightWalletEndpoint?>(nil)
        let sameServerSnapshot = snapshot(syncHost: "testnet.zec.rocks", broadcastHost: "testnet.zec.rocks")

        let didSwitch = await withDependencies {
            $0.userStoredPreferences.automaticServerSelection = { true }
            $0.userStoredPreferences.setServer = { _ in }
            $0.zcashSDKEnvironment = .testnet
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            $0.zcashSDKEnvironment.endpoint = { self.endpoint("na.zec.rocks") }
            $0.sdkSynchronizer.switchToEndpoint = { switchedTo.setValue($0) }
            $0.transactionGuard = TransactionGuardClient(acquire: {}, tryAcquire: { true }, release: {})
            $0.migrationManager.activeNetworkSnapshots = { [sameServerSnapshot] }
        } operation: {
            await AutoServerSelectionClient.liveValue.applySwitch(endpoint("eu.zec.rocks"))
        }

        #expect(didSwitch == true)
        #expect(switchedTo.value?.host == "eu.zec.rocks")
    }
}
