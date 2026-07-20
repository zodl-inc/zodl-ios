//
//  MigrationFailureRoutingTests.swift
//  zodlTests
//
//  Covers MOB-1497's R7-T3 failure-routing subsystem end to end on the manager side:
//  `MigrationFailureRoutingStorage` (Dependencies/MigrationManager/MigrationManagerLiveKey.swift) —
//  the had-broadcast flag (R14 first-run vs R15 mid-run) and the R16 per-account episode set — and
//  `MigrationManagerImpl.routeBroadcastFailure`'s decision table over that storage plus a committed
//  `MigrationNetworkSnapshot`. Kept in one file (rather than split further, or folded into the
//  already-2800+-line `MigrationManagerTests.swift`) since the storage class and the routing member
//  are one cohesive new subsystem with no other consumers yet. The pure classifier
//  (`MigrationBroadcastFailureClass.classify`) has its own `MigrationBroadcastFailureTests`; the
//  sanctioned `MigrationSnapshotStorage` mutations (`overrideUseTorForCommitted`/
//  `rotateBroadcastEndpoint`/`overrideBroadcastEndpointToSyncServerForCommitted`) are pinned directly
//  in `MigrationSnapshotStorageTests` beside that class's other tests. `.serialized`: every storage
//  test shares the `UserDefaults` global (same reasoning as the sibling storage test files).
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized)
struct MigrationFailureRoutingTests {
    private static func accountUUID(_ byte: UInt8) -> AccountUUID {
        AccountUUID(id: [UInt8](repeating: byte, count: 16))
    }

    private static func snapshot(
        useTor: Bool = false,
        syncHost: String = "zec.rocks",
        broadcastHost: String = "us.zec.stardust.rest",
        takenAt: Date = Date(timeIntervalSince1970: 1_000_000),
        committedAt: Date? = Date(timeIntervalSince1970: 1_000_500)
    ) -> MigrationNetworkSnapshot {
        MigrationNetworkSnapshot(
            useTor: useTor,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: syncHost, port: 443, secure: true),
            syncProvider: ServerProvider.classify(host: syncHost),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: broadcastHost, port: 443, secure: true),
            broadcastProvider: ServerProvider.classify(host: broadcastHost),
            takenAt: takenAt,
            committedAt: committedAt
        )
    }

    // MARK: - MigrationFailureRoutingStorage: had-broadcast flag

    @Test func hadBroadcastDefaultsFalse() throws {
        try withRoutingStorage("testHadBroadcastDefaultsFalse") { storage in
            #expect(storage.hadBroadcast(for: Self.accountUUID(1)) == false)
        }
    }

    @Test func markHadBroadcastSetsTheFlag() throws {
        try withRoutingStorage("testMarkHadBroadcastSetsTheFlag") { storage in
            let accountUUID = Self.accountUUID(2)

            storage.markHadBroadcast(for: accountUUID)

            #expect(storage.hadBroadcast(for: accountUUID) == true)
        }
    }

    @Test func markHadBroadcastResetsTheEpisode() throws {
        try withRoutingStorage("testMarkHadBroadcastResetsTheEpisode") { storage in
            let accountUUID = Self.accountUUID(3)
            storage.addEpisodeHost("na.zec.rocks", for: accountUUID)
            #expect(storage.episodeHosts(for: accountUUID) == ["na.zec.rocks"])

            storage.markHadBroadcast(for: accountUUID)

            #expect(storage.episodeHosts(for: accountUUID).isEmpty)
        }
    }

    @Test func clearResetsBothTheFlagAndTheEpisode() throws {
        try withRoutingStorage("testClearResetsBothTheFlagAndTheEpisode") { storage in
            let accountUUID = Self.accountUUID(4)
            storage.markHadBroadcast(for: accountUUID)
            storage.addEpisodeHost("na.zec.rocks", for: accountUUID)

            storage.clear(for: accountUUID)

            #expect(storage.hadBroadcast(for: accountUUID) == false)
            #expect(storage.episodeHosts(for: accountUUID).isEmpty)
        }
    }

    @Test func perAccountFlagsAndEpisodesAreIsolated() throws {
        try withRoutingStorage("testPerAccountFlagsAndEpisodesAreIsolated") { storage in
            let accountA = Self.accountUUID(5)
            let accountB = Self.accountUUID(6)
            storage.markHadBroadcast(for: accountA)
            storage.addEpisodeHost("na.zec.rocks", for: accountA)

            #expect(storage.hadBroadcast(for: accountB) == false)
            #expect(storage.episodeHosts(for: accountB).isEmpty)
        }
    }

    // MARK: - MigrationFailureRoutingStorage: episode set

    @Test func episodeHostsDefaultsEmpty() throws {
        try withRoutingStorage("testEpisodeHostsDefaultsEmpty") { storage in
            #expect(storage.episodeHosts(for: Self.accountUUID(7)).isEmpty)
        }
    }

    @Test func addEpisodeHostAppendsAndReturnsTheFullSet() throws {
        try withRoutingStorage("testAddEpisodeHostAppendsAndReturnsTheFullSet") { storage in
            let accountUUID = Self.accountUUID(8)

            let afterFirst = storage.addEpisodeHost("na.zec.rocks", for: accountUUID)
            let afterSecond = storage.addEpisodeHost("sa.zec.rocks", for: accountUUID)

            #expect(afterFirst == ["na.zec.rocks"])
            #expect(afterSecond == ["na.zec.rocks", "sa.zec.rocks"])
            #expect(storage.episodeHosts(for: accountUUID) == ["na.zec.rocks", "sa.zec.rocks"])
        }
    }

    @Test func addEpisodeHostIsIdempotentForTheSameHost() throws {
        try withRoutingStorage("testAddEpisodeHostIsIdempotentForTheSameHost") { storage in
            let accountUUID = Self.accountUUID(9)

            storage.addEpisodeHost("na.zec.rocks", for: accountUUID)
            let result = storage.addEpisodeHost("na.zec.rocks", for: accountUUID)

            #expect(result == ["na.zec.rocks"])
        }
    }

    @Test func resetEpisodeClearsOnlyTheEpisodeNotTheFlag() throws {
        try withRoutingStorage("testResetEpisodeClearsOnlyTheEpisodeNotTheFlag") { storage in
            let accountUUID = Self.accountUUID(10)
            storage.markHadBroadcast(for: accountUUID)
            storage.addEpisodeHost("na.zec.rocks", for: accountUUID)

            storage.resetEpisode(for: accountUUID)

            #expect(storage.episodeHosts(for: accountUUID).isEmpty)
            #expect(storage.hadBroadcast(for: accountUUID) == true)
        }
    }

    // MARK: - routeBroadcastFailure: defensive no-committed-snapshot fallback

    @Test func routeBroadcastFailureWithNoSnapshotAtAllReturnsPlainRetry() async throws {
        try await withImpl("testRouteBroadcastFailureWithNoSnapshotAtAllReturnsPlainRetry") { impl, account, _ in
            let route = await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.endpointUnreachable)

            #expect(route == MigrationBroadcastFailureRoute.plainRetry)
        }
    }

    @Test func routeBroadcastFailureWithOnlyAProvisionalSnapshotReturnsPlainRetry() async throws {
        try await withImpl("testRouteBroadcastFailureWithOnlyAProvisionalSnapshotReturnsPlainRetry") { impl, account, storages in
            storages.snapshotStorage.recordSnapshot(Self.snapshot(committedAt: nil), for: account.id)

            let route = await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.torUnavailable)

            #expect(route == MigrationBroadcastFailureRoute.plainRetry)
        }
    }

    // MARK: - routeBroadcastFailure: Tor-class (R14/R15) — never rotates, never touches the episode

    @Test func torUnavailableFirstRunReturnsTorFirstRunChoice() async throws {
        try await withImpl("testTorUnavailableFirstRunReturnsTorFirstRunChoice") { impl, account, storages in
            storages.snapshotStorage.recordSnapshot(Self.snapshot(broadcastHost: "us.zec.stardust.rest"), for: account.id)

            let route = await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.torUnavailable)

            #expect(route == MigrationBroadcastFailureRoute.torFirstRunChoice)
            #expect(storages.snapshotStorage.snapshot(for: account.id)?.broadcastEndpoint.host == "us.zec.stardust.rest")
            #expect(storages.failureRoutingStorage.episodeHosts(for: account.id).isEmpty)
        }
    }

    @Test func torUnavailableMidRunReturnsTorHold() async throws {
        try await withImpl("testTorUnavailableMidRunReturnsTorHold") { impl, account, storages in
            storages.snapshotStorage.recordSnapshot(Self.snapshot(broadcastHost: "us.zec.stardust.rest"), for: account.id)
            storages.failureRoutingStorage.markHadBroadcast(for: account.id)

            let route = await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.torUnavailable)

            #expect(route == MigrationBroadcastFailureRoute.torHold)
            #expect(storages.snapshotStorage.snapshot(for: account.id)?.broadcastEndpoint.host == "us.zec.stardust.rest")
            #expect(storages.failureRoutingStorage.episodeHosts(for: account.id).isEmpty)
        }
    }

    // MARK: - routeBroadcastFailure: endpoint-class, same-server exemption (R16)

    @Test func endpointUnreachableOnIdentityCustomSnapshotReturnsPlainRetryWithNoEpisodeTracking() async throws {
        try await withImpl("testEndpointUnreachableOnIdentityCustomSnapshotReturnsPlainRetryWithNoEpisodeTracking") { impl, account, storages in
            storages.snapshotStorage.recordSnapshot(
                Self.snapshot(syncHost: "myserver.example.com", broadcastHost: "myserver.example.com"),
                for: account.id
            )

            let route = await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.endpointUnreachable)

            #expect(route == MigrationBroadcastFailureRoute.plainRetry)
            #expect(storages.failureRoutingStorage.episodeHosts(for: account.id).isEmpty)
        }
    }

    @Test func endpointUnreachableOnTestnetShapedSameServerSnapshotReturnsPlainRetryWithNoEpisodeTracking() async throws {
        try await withImpl("testEndpointUnreachableOnTestnetShapedSameServerSnapshotReturnsPlainRetryWithNoEpisodeTracking") { impl, account, storages in
            // Same-provider-but-not-custom shape: the defensive empty-candidates/testnet fallback
            // `createNetworkSnapshot` produces (`broadcastProvider == syncProvider` without either
            // being `.custom`).
            storages.snapshotStorage.recordSnapshot(
                Self.snapshot(syncHost: "zec.rocks", broadcastHost: "na.zec.rocks"),
                for: account.id
            )

            let route = await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.endpointUnreachable)

            #expect(route == MigrationBroadcastFailureRoute.plainRetry)
            #expect(storages.failureRoutingStorage.episodeHosts(for: account.id).isEmpty)
        }
    }

    // MARK: - routeBroadcastFailure: endpoint-class, provider snapshot — rotation (R16)

    @Test func endpointUnreachableOnProviderSnapshotGrowsTheEpisodeAndRotatesToASeededUntriedHost() async throws {
        try await withImpl("testEndpointUnreachableOnProviderSnapshotGrowsTheEpisodeAndRotatesToASeededUntriedHost") { impl, account, storages in
            // P1 (zecRocks) sync -> P2 (stardust) broadcast; current broadcast host is one of the
            // TWO stardust members. A rotation within a 2-member family has only one place to go.
            storages.snapshotStorage.recordSnapshot(
                Self.snapshot(useTor: true, syncHost: "zec.rocks", broadcastHost: "us.zec.stardust.rest"),
                for: account.id
            )
            let capturedCandidateCount = LockIsolated<Int?>(nil)

            let route = await withDependencies {
                $0.zcashSDKEnvironment = .testnet
                $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
                $0.migrationRandomness.randomIndex = { count in
                    capturedCandidateCount.setValue(count)
                    return 0
                }
            } operation: {
                await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.endpointUnreachable)
            }

            #expect(route == MigrationBroadcastFailureRoute.retryRotated)
            // Only ONE untried stardust host remains once the current one is excluded.
            #expect(capturedCandidateCount.value == 1)

            let updated = try #require(storages.snapshotStorage.snapshot(for: account.id))
            #expect(updated.broadcastEndpoint.host == "eu.zec.stardust.rest")
            #expect(updated.broadcastProvider == ServerProvider.stardust)
            #expect(updated.useTor == true)
            #expect(updated.syncEndpoint.host == "zec.rocks")

            // The FAILED (pre-rotation) host — never the newly-rotated one, never a sync-provider
            // host — is what's recorded as tried.
            #expect(storages.failureRoutingStorage.episodeHosts(for: account.id) == ["us.zec.stardust.rest"])
        }
    }

    /// A different seeded draw over a larger (P1, 5-member) family lands on a DIFFERENT untried
    /// host, proving the pick genuinely varies with the draw rather than a hardcoded fallback.
    @Test func endpointUnreachableOnLargerProviderFamilyRotatesToTheSeededIndexAmongUntriedHosts() async throws {
        try await withImpl("testEndpointUnreachableOnLargerProviderFamilyRotatesToTheSeededIndexAmongUntriedHosts") { impl, account, storages in
            // P2 (stardust) sync -> P1 (zecRocks) broadcast, 5 members. Current host + one more are
            // already in the episode, leaving 3 untried: zec.rocks, sa.zec.rocks, ap.zec.rocks (na
            // and eu excluded).
            storages.snapshotStorage.recordSnapshot(
                Self.snapshot(syncHost: "us.zec.stardust.rest", broadcastHost: "na.zec.rocks"),
                for: account.id
            )
            storages.failureRoutingStorage.addEpisodeHost("eu.zec.rocks", for: account.id)

            let route = await withDependencies {
                $0.zcashSDKEnvironment = .testnet
                $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
                $0.migrationRandomness.randomIndex = { _ in 2 } // 3rd untried candidate, in list order
            } operation: {
                await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.endpointUnreachable)
            }

            #expect(route == MigrationBroadcastFailureRoute.retryRotated)
            let updated = try #require(storages.snapshotStorage.snapshot(for: account.id))
            // Untried-in-list-order: zec.rocks(0), sa.zec.rocks(1), ap.zec.rocks(2).
            #expect(updated.broadcastEndpoint.host == "ap.zec.rocks")
            #expect(storages.failureRoutingStorage.episodeHosts(for: account.id) == ["eu.zec.rocks", "na.zec.rocks"])
        }
    }

    // MARK: - routeBroadcastFailure: endpoint-class, provider exhaustion (R17)

    @Test func endpointUnreachableWithEveryStardustHostAlreadyTriedReturnsProviderExhaustedWithoutMutating() async throws {
        try await withImpl("testEndpointUnreachableWithEveryStardustHostAlreadyTriedReturnsProviderExhaustedWithoutMutating") { impl, account, storages in
            storages.snapshotStorage.recordSnapshot(
                Self.snapshot(useTor: true, syncHost: "zec.rocks", broadcastHost: "us.zec.stardust.rest"),
                for: account.id
            )
            storages.failureRoutingStorage.addEpisodeHost("eu.zec.stardust.rest", for: account.id)
            // The current host itself is the ONLY one not yet in the episode going in — this call
            // must add it too, exhausting the 2-member P2 family.

            let route = await withDependencies {
                $0.zcashSDKEnvironment = .testnet
                $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
                $0.migrationRandomness.randomIndex = { _ in 0 }
            } operation: {
                await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.endpointUnreachable)
            }

            #expect(route == MigrationBroadcastFailureRoute.providerExhausted(torEnabled: true))
            // No rotation — the snapshot's broadcast endpoint is exactly as it was.
            #expect(storages.snapshotStorage.snapshot(for: account.id)?.broadcastEndpoint.host == "us.zec.stardust.rest")

            // A REPEATED call keeps returning exhausted (the episode stays full).
            let secondRoute = await withDependencies {
                $0.zcashSDKEnvironment = .testnet
                $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
                $0.migrationRandomness.randomIndex = { _ in 0 }
            } operation: {
                await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.endpointUnreachable)
            }
            #expect(secondRoute == MigrationBroadcastFailureRoute.providerExhausted(torEnabled: true))
            #expect(storages.snapshotStorage.snapshot(for: account.id)?.broadcastEndpoint.host == "us.zec.stardust.rest")
        }
    }

    @Test func providerExhaustedReflectsTheSnapshotsTorFlag() async throws {
        try await withImpl("testProviderExhaustedReflectsTheSnapshotsTorFlag") { impl, account, storages in
            storages.snapshotStorage.recordSnapshot(
                Self.snapshot(useTor: false, syncHost: "zec.rocks", broadcastHost: "us.zec.stardust.rest"),
                for: account.id
            )
            storages.failureRoutingStorage.addEpisodeHost("eu.zec.stardust.rest", for: account.id)

            let route = await withDependencies {
                $0.zcashSDKEnvironment = .testnet
                $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
                $0.migrationRandomness.randomIndex = { _ in 0 }
            } operation: {
                await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.endpointUnreachable)
            }

            #expect(route == MigrationBroadcastFailureRoute.providerExhausted(torEnabled: false))
        }
    }

    /// The end-to-end integration the spec calls out explicitly: exhaustion, then a landed
    /// broadcast (`recordTransferBroadcast`), then the NEXT failure sees a fresh episode.
    @Test func landedBroadcastResetsTheEpisodeSoTheNextFailureStartsFresh() async throws {
        try await withImpl("testLandedBroadcastResetsTheEpisodeSoTheNextFailureStartsFresh") { impl, account, storages in
            storages.snapshotStorage.recordSnapshot(
                Self.snapshot(syncHost: "zec.rocks", broadcastHost: "us.zec.stardust.rest"),
                for: account.id
            )
            storages.failureRoutingStorage.addEpisodeHost("eu.zec.stardust.rest", for: account.id)

            let exhaustedRoute = await withDependencies {
                $0.zcashSDKEnvironment = .testnet
                $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
                $0.migrationRandomness.randomIndex = { _ in 0 }
            } operation: {
                await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.endpointUnreachable)
            }
            #expect(exhaustedRoute == MigrationBroadcastFailureRoute.providerExhausted(torEnabled: false))

            await impl.recordTransferBroadcast(accountUUID: account.id, result: MigrationTransferResult.success(txId: "tx-landed"))
            #expect(storages.failureRoutingStorage.episodeHosts(for: account.id).isEmpty)
            #expect(storages.failureRoutingStorage.hadBroadcast(for: account.id) == true)

            let freshRoute = await withDependencies {
                $0.zcashSDKEnvironment = .testnet
                $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
                $0.migrationRandomness.randomIndex = { _ in 0 }
            } operation: {
                await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.endpointUnreachable)
            }
            #expect(freshRoute == MigrationBroadcastFailureRoute.retryRotated)

            // The Tor-class route also now reads mid-run, since a broadcast has landed.
            let torRoute = await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.torUnavailable)
            #expect(torRoute == MigrationBroadcastFailureRoute.torHold)
        }
    }

    // MARK: - overrideTorForRun / overrideBroadcastEndpointToSyncServer via migrationNetworkOptions

    @Test func overrideTorForRunReflectsInMigrationNetworkOptionsWithEndpointUnchanged() async throws {
        try await withImpl("testOverrideTorForRunReflectsInMigrationNetworkOptionsWithEndpointUnchanged") { impl, account, storages in
            storages.snapshotStorage.recordSnapshot(
                Self.snapshot(useTor: true, syncHost: "zec.rocks", broadcastHost: "us.zec.stardust.rest"),
                for: account.id
            )

            impl.overrideTorForRun(accountUUID: account.id, useTor: false)

            let options = await impl.migrationNetworkOptions(accountUUID: account.id)
            #expect(options.useTor == false)
            #expect(options.submissionEndpoint.host == "us.zec.stardust.rest")
        }
    }

    @Test func overrideBroadcastEndpointToSyncServerReflectsInMigrationNetworkOptionsAndResetsEpisode() async throws {
        try await withImpl("testOverrideBroadcastEndpointToSyncServerReflectsInMigrationNetworkOptionsAndResetsEpisode") { impl, account, storages in
            storages.snapshotStorage.recordSnapshot(
                Self.snapshot(useTor: true, syncHost: "eu.zec.rocks", broadcastHost: "us.zec.stardust.rest"),
                for: account.id
            )
            storages.failureRoutingStorage.addEpisodeHost("us.zec.stardust.rest", for: account.id)
            storages.failureRoutingStorage.addEpisodeHost("eu.zec.stardust.rest", for: account.id)

            await impl.overrideBroadcastEndpointToSyncServer(accountUUID: account.id)

            let options = await impl.migrationNetworkOptions(accountUUID: account.id)
            #expect(options.submissionEndpoint.host == "eu.zec.rocks")
            #expect(storages.failureRoutingStorage.episodeHosts(for: account.id).isEmpty)
        }
    }

    /// R17's own doc promise: once overridden, the snapshot is same-server, so a LATER
    /// endpoint-class failure takes the same-server exemption naturally instead of rotating/
    /// exhausting again.
    @Test func afterSyncServerOverrideALaterEndpointFailureTakesTheSameServerExemption() async throws {
        try await withImpl("testAfterSyncServerOverrideALaterEndpointFailureTakesTheSameServerExemption") { impl, account, storages in
            storages.snapshotStorage.recordSnapshot(
                Self.snapshot(useTor: true, syncHost: "eu.zec.rocks", broadcastHost: "us.zec.stardust.rest"),
                for: account.id
            )

            await impl.overrideBroadcastEndpointToSyncServer(accountUUID: account.id)

            let route = await impl.routeBroadcastFailure(accountUUID: account.id, failureClass: MigrationBroadcastFailureClass.endpointUnreachable)
            #expect(route == MigrationBroadcastFailureRoute.plainRetry)
        }
    }

    // MARK: - recordTransferBroadcast: had-broadcast flag lifecycle (manager-level)

    @Test func recordTransferBroadcastSuccessSetsHadBroadcast() async throws {
        try await withImpl("testRecordTransferBroadcastSuccessSetsHadBroadcast") { impl, account, storages in
            await impl.recordTransferBroadcast(accountUUID: account.id, result: MigrationTransferResult.success(txId: "tx-0"))

            #expect(storages.failureRoutingStorage.hadBroadcast(for: account.id) == true)
        }
    }

    @Test func recordTransferBroadcastNonSuccessDoesNotSetHadBroadcast() async throws {
        try await withImpl("testRecordTransferBroadcastNonSuccessDoesNotSetHadBroadcast") { impl, account, storages in
            await impl.recordTransferBroadcast(accountUUID: account.id, result: MigrationTransferResult.networkError(retryable: true))

            #expect(storages.failureRoutingStorage.hadBroadcast(for: account.id) == false)
        }
    }

    // MARK: - Run-end trio: acknowledgeComplete / resetPersistedFlags / reconcile clear the flag+episode

    @Test func acknowledgeCompleteClearsTheSelectedAccountsFailureRoutingState() async throws {
        try await withImpl("testAcknowledgeCompleteClearsTheSelectedAccountsFailureRoutingState") { impl, account, storages in
            storages.failureRoutingStorage.markHadBroadcast(for: account.id)
            storages.failureRoutingStorage.addEpisodeHost("na.zec.rocks", for: account.id)

            impl.acknowledgeComplete()

            #expect(storages.failureRoutingStorage.hadBroadcast(for: account.id) == false)
            #expect(storages.failureRoutingStorage.episodeHosts(for: account.id).isEmpty)
        }
    }

    @Test func resetPersistedFlagsClearsEveryKnownAccountsFailureRoutingState() async throws {
        try await withImpl("testResetPersistedFlagsClearsEveryKnownAccountsFailureRoutingState") { impl, account, storages in
            @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
            let otherAccount = WalletAccount(
                Account(
                    id: Self.accountUUID(99),
                    name: "Keystone",
                    keySource: String(localizable: .accountsKeystone).lowercased(),
                    seedFingerprint: nil,
                    hdAccountIndex: Zip32AccountIndex(0),
                    ufvk: nil,
                    uivk: nil
                )
            )
            // `resetPersistedFlags()` iterates `walletAccounts` — the "other" account must actually
            // be a member of it for the loop to reach it (the selected-account branch alone would
            // only ever cover `account`).
            $walletAccounts.withLock { $0 = [account, otherAccount] }
            storages.failureRoutingStorage.markHadBroadcast(for: account.id)
            storages.failureRoutingStorage.markHadBroadcast(for: otherAccount.id)
            storages.failureRoutingStorage.addEpisodeHost("na.zec.rocks", for: otherAccount.id)

            impl.resetPersistedFlags()

            #expect(storages.failureRoutingStorage.hadBroadcast(for: account.id) == false)
            #expect(storages.failureRoutingStorage.hadBroadcast(for: otherAccount.id) == false)
            #expect(storages.failureRoutingStorage.episodeHosts(for: otherAccount.id).isEmpty)
        }
    }

    @Test func reconcileClearsFailureRoutingStateAlongsideAStaleNotStartedSchedule() async throws {
        try await withImpl("testReconcileClearsFailureRoutingStateAlongsideAStaleNotStartedSchedule") { impl, account, storages in
            let schedule = MigrationSchedule(
                transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(100), anchorHeight: 10, nextExecutableAfterHeight: 10, expiryHeight: 20)],
                estimatedDurationHours: 6
            )
            storages.scheduleStorage.recordCommittedSchedule(schedule, for: account.id, now: Date())
            storages.failureRoutingStorage.markHadBroadcast(for: account.id)
            storages.failureRoutingStorage.addEpisodeHost("na.zec.rocks", for: account.id)

            await withDependencies {
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: {
                        var state = SynchronizerState.zero
                        state.latestBlockHeight = 5_000_000
                        return state
                    }
                )
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.notStarted }
            } operation: {
                await impl.reconcile()
            }

            #expect(storages.failureRoutingStorage.hadBroadcast(for: account.id) == false)
            #expect(storages.failureRoutingStorage.episodeHosts(for: account.id).isEmpty)
        }
    }

    // MARK: - Test scaffolding

    private struct Storages {
        let gateStorage: MigrationGateStorage
        let scheduleStorage: MigrationScheduleStorage
        let snapshotStorage: MigrationSnapshotStorage
        let failureRoutingStorage: MigrationFailureRoutingStorage
    }

    /// Fresh isolated `UserDefaults` suites per storage class + a selected `WalletAccount`, mirroring
    /// `MigrationManagerTests`' own per-test fixture shape. `name` seeds every suite so parallel
    /// `@Test`s (this suite is `.serialized`, but the naming discipline still documents intent)
    /// never collide.
    private func withRoutingStorage(_ name: String, _ body: (MigrationFailureRoutingStorage) throws -> Void) throws {
        let userDefaults = try #require(UserDefaults(suiteName: name), "MigrationFailureRoutingStorage: UserDefaults failed to initialize")
        defer { userDefaults.removePersistentDomain(forName: name) }
        try body(MigrationFailureRoutingStorage(userDefaults: userDefaults))
    }

    private func withImpl(
        _ name: String,
        _ body: (MigrationManagerImpl, WalletAccount, Storages) async throws -> Void
    ) async throws {
        let gateSuite = "\(name)Gate"
        let scheduleSuite = "\(name)Schedule"
        let snapshotSuite = "\(name)Snapshot"
        let routingSuite = "\(name)Routing"
        let gateUserDefaults = try #require(UserDefaults(suiteName: gateSuite))
        let scheduleUserDefaults = try #require(UserDefaults(suiteName: scheduleSuite))
        let snapshotUserDefaults = try #require(UserDefaults(suiteName: snapshotSuite))
        let routingUserDefaults = try #require(UserDefaults(suiteName: routingSuite))
        defer {
            gateUserDefaults.removePersistentDomain(forName: gateSuite)
            scheduleUserDefaults.removePersistentDomain(forName: scheduleSuite)
            snapshotUserDefaults.removePersistentDomain(forName: snapshotSuite)
            routingUserDefaults.removePersistentDomain(forName: routingSuite)
        }

        let storages = Storages(
            gateStorage: MigrationGateStorage(userDefaults: gateUserDefaults),
            scheduleStorage: MigrationScheduleStorage(userDefaults: scheduleUserDefaults),
            snapshotStorage: MigrationSnapshotStorage(userDefaults: snapshotUserDefaults),
            failureRoutingStorage: MigrationFailureRoutingStorage(userDefaults: routingUserDefaults)
        )
        let impl = MigrationManagerImpl(
            gateStorage: storages.gateStorage,
            scheduleStorage: storages.scheduleStorage,
            snapshotStorage: storages.snapshotStorage,
            failureRoutingStorage: storages.failureRoutingStorage
        )

        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        let account = WalletAccount(
            Account(
                id: Self.accountUUID(1),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
        $selectedWalletAccount.withLock { $0 = account }

        try await body(impl, account, storages)
    }
}
