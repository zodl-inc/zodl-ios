//
//  RootMigrationRoutingTests.swift
//  zodlTests
//
//  Covers MOB-1466 phase 5's Root-level wiring for the migration flow
//  (Features/Root/{RootStore,RootCoordinator,RootInitialization}.swift): the SmartBanner-tap ->
//  `.migrationCoordFlow` route (with flow-state reset), `isSensitiveFlowActive` classifying the new
//  `Path` case, `flowFinished` closing the path, launch/foreground reconciliation invoking
//  `migrationManager.reconcile()`, and the Sending `.viewTransaction` delegate's Root-level handling
//  (v1: treated as a flow close — see the `RootCoordinator` doc comment at that case for why).
//
//  Also covers MOB-1467's notification-tap deep link (`.appDelegate(.migrationNotificationTapped)`):
//  immediate routing once Home/initialized, versus the deferred `pendingMigrationDeepLink` path that
//  mirrors `RootDestination`'s `isAtDeeplinkWarningScreen` gating and fires from
//  `checkBackupPhraseValidation`'s "just reached Home" checkpoint — plus the `willEnterForeground`
//  delivered-notifications clear.
//
//  `.serialized`: constructing `Root.State` builds `migrationCoordFlowState = MigrationCoordFlow
//  .State.initial`, which itself builds a `MigrationEntry.State` reading the process-global
//  `@Shared(.inMemory(.selectedWalletAccount))` key — same precedent as `MigrationCoordFlowTests`.
//  Uses a plain `Store` (not `TestStore`) with heavy `withDependencies` overrides, mirroring
//  `FlexaTests/FlexaSecurityTests.swift`: Root's init effects are too heavy for exhaustive
//  `TestStore` assertion, so behavior is observed via `LockIsolated` spies and polling.
//

import Foundation
import Testing
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RootMigrationRoutingTests {
    // MARK: - Banner tap -> .migrationCoordFlow

    /// Tapping the migration banner (`.home(.smartBanner(.migrationScreenRequested))`) must open
    /// `.migrationCoordFlow` and reset its flow state fresh — same shape as `.walletBackupTapped`
    /// opening `.walletBackup`.
    @Test func migrationScreenRequestedOpensMigrationCoordFlowWithFreshState() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            // Poison the pre-existing flow state so a reset is actually observable.
            initialState.migrationCoordFlowState.mode = MigrationMode.immediate
            initialState.migrationCoordFlowState.path.append(.complete(MigrationComplete.State()))

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
            }

            store.send(.home(.smartBanner(.migrationScreenRequested)))
            await waitForRootStore { store.state.path == Root.State.Path.migrationCoordFlow }

            #expect(store.state.path == Root.State.Path.migrationCoordFlow)
            #expect(store.state.migrationCoordFlowState.mode == nil)
            #expect(store.state.migrationCoordFlowState.path.isEmpty)
        }
    }

    // MARK: - flowFinished -> path == nil

    /// `MigrationCoordFlow`'s `.flowFinished` (every flow-root close / terminal delegate) must
    /// close the migration path back to Home.
    @Test func migrationCoordFlowFinishedClosesPath() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.path = Root.State.Path.migrationCoordFlow

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
            }

            store.send(.migrationCoordFlow(.flowFinished))
            await waitForRootStore { store.state.path == nil }

            #expect(store.state.path == nil)
        }
    }

    // MARK: - isSensitiveFlowActive

    /// Pure computed-property check: `.migrationCoordFlow` must classify as sensitive, alongside
    /// send/scan/swap/transactions — the exhaustive switch forces this classification by design.
    @Test func isSensitiveFlowActiveIsTrueForMigrationCoordFlow() {
        var state = Root.State.initial
        state.path = Root.State.Path.migrationCoordFlow

        #expect(state.isSensitiveFlowActive == true)
    }

    // MARK: - Reconciliation: willEnterForeground

    /// Every foreground entry must invoke `migrationManager.reconcile()`, regardless of the
    /// keychain/sync-status branch taken afterward.
    @Test func willEnterForegroundInvokesMigrationReconcile() async {
        let reconcileCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            }

            store.send(.initialization(.appDelegate(.willEnterForeground)))
            await waitForRootStore { reconcileCalls.withValue { $0 } == 1 }

            #expect(reconcileCalls.withValue { $0 } == 1)
        }
    }

    // MARK: - Reconciliation: launch (initialSetups)

    /// The launch path (`initialSetups`, past the disk-space guard) must also invoke
    /// `migrationManager.reconcile()`, independent of `willEnterForeground`'s own hook.
    @Test func initialSetupsInvokesMigrationReconcile() async {
        let reconcileCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
            }

            store.send(.initialization(.initialSetups))
            await waitForRootStore { reconcileCalls.withValue { $0 } == 1 }

            #expect(reconcileCalls.withValue { $0 } == 1)
        }
    }

    // MARK: - View Transaction (Sending delegate)

    /// The migration Sending screen's `.viewTransaction` delegate carries only a bare stub
    /// `txId: String` — never a real `TransactionState` the existing transaction-detail plumbing
    /// (`TransactionDetails.State.transaction`, non-optional) could open. Root's v1 handling (see
    /// the doc comment on this case in `RootCoordinator.swift`) treats it as a flow close rather
    /// than opening a broken/empty detail screen, pending real txids from the SDK (MOB-1455).
    @Test func sendingViewTransactionDelegateClosesMigrationFlow() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.path = Root.State.Path.migrationCoordFlow
            let sendingState = MigrationSending.State(phase: .success, txId: "stub-tx-id")
            initialState.migrationCoordFlowState.path.append(.sending(sendingState))

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
            }

            let sendingId = try? #require(initialState.migrationCoordFlowState.path.ids.last)
            guard let sendingId else {
                Issue.record("Expected a sending element id on the migration path")
                return
            }

            store.send(
                .migrationCoordFlow(
                    .path(.element(id: sendingId, action: .sending(.delegate(.viewTransaction))))
                )
            )
            await waitForRootStore { store.state.path == nil }

            #expect(store.state.path == nil)
        }
    }

    // MARK: - MOB-1467: Notification-tap deep link

    /// Tapping a migration notification while Home is already up/initialized must route
    /// immediately — exactly the SmartBanner-tap routing (fresh flow state, `.migrationCoordFlow`).
    @Test func migrationNotificationTappedOnInitializedStateRoutesImmediately() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.appInitializationState = InitializationState.initialized
            // Poison the pre-existing flow state so a reset is actually observable, same as the
            // banner-tap test above.
            initialState.migrationCoordFlowState.mode = MigrationMode.immediate
            initialState.migrationCoordFlowState.path.append(.complete(MigrationComplete.State()))

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
            }

            store.send(.initialization(.appDelegate(.migrationNotificationTapped)))
            await waitForRootStore { store.state.path == Root.State.Path.migrationCoordFlow }

            #expect(store.state.path == Root.State.Path.migrationCoordFlow)
            #expect(store.state.migrationCoordFlowState.mode == nil)
            #expect(store.state.migrationCoordFlowState.path.isEmpty)
            #expect(store.state.pendingMigrationDeepLink == false)
        }
    }

    /// Tapping a migration notification BEFORE the app has reached Home (cold start still in
    /// flight) must stash the request rather than drop it — mirrors `RootDestination`'s
    /// `isAtDeeplinkWarningScreen` gating. It then fires once `checkBackupPhraseValidation` (the
    /// checkpoint that sets `appInitializationState = .initialized`) runs, exactly like a deferred
    /// deep link is released there.
    @Test func migrationNotificationTappedBeforeInitializedStashesThenFiresAtCheckBackupPhraseValidation() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.appInitializationState = InitializationState.uninitialized

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
            }

            store.send(.initialization(.appDelegate(.migrationNotificationTapped)))
            await waitForRootStore { store.state.pendingMigrationDeepLink == true }

            #expect(store.state.pendingMigrationDeepLink == true)
            #expect(store.state.path == nil)

            store.send(.initialization(.checkBackupPhraseValidation))
            await waitForRootStore { store.state.path == Root.State.Path.migrationCoordFlow }

            #expect(store.state.path == Root.State.Path.migrationCoordFlow)
            #expect(store.state.pendingMigrationDeepLink == false)
        }
    }

    // MARK: - MOB-1467: Foreground-clear of delivered migration notifications

    /// Every foreground entry must clear DELIVERED migration notifications (the banner/re-entry
    /// route now carries the current state) — but must not cancel PENDING ones (a manual-mode
    /// "ready to send" reminder must survive), so this only asserts the delivered-clear spy, never
    /// `cancelMigrationNotifications`.
    @Test func willEnterForegroundClearsDeliveredMigrationNotifications() async {
        let clearDeliveredCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.userNotifications.clearDeliveredMigrationNotifications = {
                    clearDeliveredCalls.withValue { $0 += 1 }
                }
            }

            store.send(.initialization(.appDelegate(.willEnterForeground)))
            await waitForRootStore { clearDeliveredCalls.withValue { $0 } == 1 }

            #expect(clearDeliveredCalls.withValue { $0 } == 1)
        }
    }
}

// MARK: - Shared dependency baseline

/// Base override set for driving a full `Root` `Store` without its heavy init effects crashing on
/// unimplemented dependency defaults — mirrors `FlexaSecurityTests`' override set, plus the
/// migration-specific clients and the `.initialization(...)` launch-path dependencies (`
/// databaseFiles`, `diskSpaceChecker`) this suite's reconciliation tests additionally traverse.
/// `diskSpaceChecker` defaults to "full disk" (`hasEnoughFreeSpaceForSync == false`) so a bare
/// `.willEnterForeground` send — which can itself fall through to `.initialSetups` — doesn't
/// also run `initialSetups`'s own reconcile effect and double-count the spy; tests that need the
/// `initialSetups` continuation (past the disk-space guard) override it back to `true` locally.
@MainActor
private func baseNoOpDependencies(_ values: inout DependencyValues) {
    values.databaseFiles = .noOp
    values.derivationTool = .liveValue
    values.diskSpaceChecker = .mockFullDisk
    values.flexaHandler = .noOp
    values.localAuthentication = .mockAuthenticationSucceeded
    values.mainQueue = .immediate
    values.mnemonic = .mock
    values.migrationBGScheduler.backgroundRefreshStatus = { .available }
    values.migrationBGScheduler.scheduleFirstWindow = { }
    values.migrationBGScheduler.scheduleNextWindow = { }
    values.migrationBGScheduler.cancelAll = { }
    values.migrationManager.bannerVariant = { _ in nil }
    values.migrationManager.reentryRoute = { .entry }
    values.migrationManager.migrationMode = { nil }
    values.migrationManager.setMigrationMode = { _ in }
    values.migrationManager.setManualDelivery = { _ in }
    values.migrationManager.setNetworkPrivacyOptions = { _ in }
    values.migrationManager.acknowledgeComplete = { }
    values.migrationManager.reconcile = { }
    values.migrationManager.recordSyncCompleted = { }
    values.readTransactionsStorage.resetZashi = { }
    values.sdkSynchronizer = .noOp
    values.userMetadataProvider.load = { _ in }
    values.userNotifications.authorizationStatus = { .notDetermined }
    values.userNotifications.requestAuthorization = { false }
    values.walletStorage = .noOp
    values.zcashSDKEnvironment = .testnet
}

@MainActor
private func waitForRootStore(
    timeoutNanoseconds: UInt64 = 15_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "Timed out waiting for migration-routing Root store state", sourceLocation: sourceLocation)
}
