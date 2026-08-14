//
//  MigrationBannerUpToDateRecheckTests.swift
//  zodlTests
//
//  MOB-1466 (field-caught 2026-08-03): a wallet that opened ALREADY SYNCED evaluated the migration
//  banner while the engine was still stamping its final pass — the Goal-1 offer gate correctly
//  declined ("wallet not caught up"), the ladder walked the slot down, and currency conversion
//  (`priority8`) claimed it. When `.upToDate` landed ten seconds later, the recheck arms covered
//  only {empty, priorityMigration, priority3, priority45, priority4} — an occupant OUTSIDE that
//  set fell through silently, so the offer declined at launch was never asked again for the
//  process lifetime.
//
//  Two pins: (1) SmartBanner's `.upToDate` transition re-asks through the single funnel for ANY
//  slot occupant (the arbiter's rank guard lets `priorityMigration` (-1) displace every banner the
//  walk-down can seat); (2) Root's `didJustReachUpToDate` edge ALSO sends the funnel — the edge is
//  the one place that provably knows sync just completed, independent of the slot's state.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SmartBannerUpToDateMigrationRecheckTests {
    /// The hole itself: slot held by a banner outside the recheck set (currency conversion, as in
    /// the field log) at the `syncing → upToDate` transition. Before the fix nothing was re-asked;
    /// after it, the single funnel runs and the manager gets one fresh `bannerVariant` question.
    @Test func upToDateWithForeignOccupantStillRechecksMigration() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }
            state.priorityContent = .priority8
            state.synchronizerStatusSnapshot = SyncStatusSnapshot.snapshotFor(state: .syncing(1.0, true))

            var upToDateState = SynchronizerState.zero
            upToDateState.syncStatus = .upToDate
            let upToDate = upToDateState

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                var client = MigrationManagerClient.noOp
                client.isIronwoodActivated = { true }
                client.bannerVariant = { _ in nil }
                $0.migrationManager = client
                // The scenario IS a caught-up wallet — the nil answer must read as "nothing to
                // migrate", not as a sync-gated decline, so the gate-closed repoll stays unarmed.
                $0.sdkSynchronizer = .mocked(
                    latestState: { upToDate }
                )
            }
            store.exhaustivity = .off

            await store.send(.synchronizerStateChanged(upToDate.redacted))

            await store.receive(\.migrationReevaluationRequested)
            // The funnel's answer flows through the one shared path; a nil variant leaves the
            // occupant alone, a real one would claim the slot through the arbiter.
            await store.receive(\.migrationVariantUpdated)
        }
    }

    /// The pre-fix behavior that must SURVIVE the fix: a `.priority4` (syncing banner) occupant
    /// still takes the close-then-re-read arm, not the plain funnel — the syncing banner must not
    /// outlive the sync it narrates.
    @Test func upToDateWithSyncingOccupantStillClosesBeforeReRead() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }
            state.priorityContent = .priority4
            state.synchronizerStatusSnapshot = SyncStatusSnapshot.snapshotFor(state: .syncing(0.9, true))

            var upToDateState = SynchronizerState.zero
            upToDateState.syncStatus = .upToDate
            let upToDate = upToDateState

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
                var client = MigrationManagerClient.noOp
                client.isIronwoodActivated = { true }
                client.bannerVariant = { _ in nil }
                $0.migrationManager = client
                // Caught-up wallet — the nil re-read is a genuine "nothing to migrate", so the
                // gate-closed repoll must stay unarmed (see the sibling test above).
                $0.sdkSynchronizer = .mocked(
                    latestState: { upToDate }
                )
            }
            store.exhaustivity = .off

            await store.send(.synchronizerStateChanged(upToDate.redacted))

            await store.receive(\.closeBanner)
            await store.receive(\.migrationVariantUpdated)
        }
    }
}

@Suite(.serialized) @MainActor struct RootUpToDateEdgeBannerRecheckTests {
    /// The belt half: Root's `didJustReachUpToDate` edge sends the SmartBanner funnel directly,
    /// so the recheck is independent of the slot's state and of SmartBanner's own stream timing.
    @Test func upToDateEdgeSendsBannerReevaluation() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State(
                destinationState: Root.DestinationState(internalDestination: .home),
                exportLogsState: ExportLogs.State(),
                onboardingState: RestoreWalletCoordFlow.State(),
                phraseDisplayState: RecoveryPhraseDisplay.State(),
                walletConfig: .initial,
                welcomeState: Welcome.State()
            )
            initialState.$featureFlags.withLock { $0 = FeatureFlags(migration: true) }

            let store = TestStore(initialState: initialState) {
                Root()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.continuousClock = TestClock()
                $0.migrationManager = .noOp
                $0.walletStorage = .noOp
                $0.flexaHandler = .noOp
                $0.sdkSynchronizer = .mocked(
                    stateStream: { Empty().eraseToAnyPublisher() },
                    latestState: { SynchronizerState.zero },
                    start: { _ in },
                    stop: { }
                )
            }
            store.exhaustivity = .off

            var upToDate = SynchronizerState.zero
            upToDate.syncStatus = .upToDate
            await store.send(.synchronizerStateChanged(upToDate.redacted)) {
                $0.wasSyncUpToDateForMigration = true
            }

            await store.receive(\.home.smartBanner.migrationReevaluationRequested)
        }
    }
}
