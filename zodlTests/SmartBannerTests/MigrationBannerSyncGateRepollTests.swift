//
//  MigrationBannerSyncGateRepollTests.swift
//  zodlTests
//
//  MOB-1466 (field-caught 2026-08-03, second occurrence — at-tip cold launch): the launch walk
//  declined the migration offer ("wallet not caught up"), currency conversion took the slot — and
//  the ONLY thing that could ever re-ask was a later `syncing → upToDate` STREAM edge. That edge
//  is losable: SmartBanner's stream subscription dies with `.onDisappear` (anything covering
//  Home), and Root's belt-funnel is a single read that can race the sync-completion reconcile. In
//  the field the first sync's edge produced no re-ask and the offer stayed missing until the next
//  sync cycle, minutes later.
//
//  The pins: (1) a migration decline that lands while the sync gate is CLOSED arms the bounded
//  repoll (same machinery as the post-restore recheck), so the offer re-asks itself once the
//  wallet catches up — no stream edge required; (2) a decline with the gate OPEN (genuinely
//  nothing to migrate — banner retirement, spent-down Orchard) arms nothing.
//

@preconcurrency import Combine
import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct MigrationBannerSyncGateRepollTests {
    /// The funnel answered nil while the wallet was still catching up: the repoll must arm, and
    /// its first post-catch-up poll must feed the funnel and claim the slot through the arbiter.
    @Test func updatedNilWhileSyncGateClosedArmsRepoll() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let clock = TestClock()
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }
            state.priorityContent = .priority8

            var syncingState = SynchronizerState.zero
            syncingState.syncStatus = .syncing(1.0, true)
            let syncing = syncingState

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.continuousClock = clock
                var client = MigrationManagerClient.noOp
                client.isIronwoodActivated = { true }
                client.bannerVariant = { _ in .required }
                $0.migrationManager = client
                $0.sdkSynchronizer = .mocked(
                    latestState: { syncing }
                )
            }
            store.exhaustivity = .off

            await store.send(.migrationVariantUpdated(nil))

            await clock.advance(by: .seconds(SmartBanner.Constants.migrationRepollInterval))

            await store.receive(\.migrationVariantUpdated)
            await store.receive(\.triggerPriority)
        }
    }

    /// The retirement path must stay quiet: a nil variant with the gate OPEN means there is
    /// genuinely nothing to migrate, and no poll may run.
    @Test func updatedNilWhileGateOpenArmsNothing() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let clock = TestClock()
            let pollCount = LockIsolated(0)
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }
            state.priorityContent = .priority8

            var upToDateState = SynchronizerState.zero
            upToDateState.syncStatus = .upToDate
            let upToDate = upToDateState

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.continuousClock = clock
                var client = MigrationManagerClient.noOp
                client.isIronwoodActivated = { true }
                client.bannerVariant = { _ in
                    pollCount.withValue { $0 += 1 }
                    return .required
                }
                $0.migrationManager = client
                $0.sdkSynchronizer = .mocked(
                    latestState: { upToDate }
                )
            }
            store.exhaustivity = .off

            await store.send(.migrationVariantUpdated(nil))

            await clock.advance(by: .seconds(SmartBanner.Constants.migrationRepollInterval * 2))

            #expect(pollCount.value == 0)
        }
    }

    /// The launch shape itself: the priority walk's migration arm declines through
    /// `.migrationVariantLoaded(nil)` while the gate is closed — the walk-down continues (the
    /// occupant seats normally) AND the repoll arms behind it, so catching up raises the offer.
    @Test func walkDownDeclineWhileSyncGateClosedArmsRepoll() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let clock = TestClock()
            let answers = LockIsolated<[MigrationBannerVariant?]>([nil])
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }

            var syncingState = SynchronizerState.zero
            syncingState.syncStatus = .syncing(1.0, true)
            let syncing = syncingState

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.continuousClock = clock
                var client = MigrationManagerClient.noOp
                client.isIronwoodActivated = { true }
                client.bannerVariant = { _ in
                    answers.withValue { queue in
                        queue.isEmpty ? MigrationBannerVariant.required : queue.removeFirst()
                    }
                }
                $0.migrationManager = client
                $0.sdkSynchronizer = .mocked(
                    latestState: { syncing }
                )
            }
            store.exhaustivity = .off

            await store.send(.evaluatePriorityMigration)

            await store.receive(\.migrationVariantLoaded)
            await store.receive(\.evaluatePriority3)

            await clock.advance(by: .seconds(SmartBanner.Constants.migrationRepollInterval))

            await store.receive(\.migrationVariantUpdated)
            await store.receive(\.triggerPriority)
        }
    }
}
