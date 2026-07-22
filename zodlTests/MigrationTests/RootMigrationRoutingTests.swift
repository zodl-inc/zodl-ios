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
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RootMigrationRoutingTests {
    /// R8-T5 (S4): a second account for the notification-tap account-switch tests — distinct
    /// `idByte` from a plain `Root.State.initial` selection, mirroring `RootMigrationBackgroundTests
    /// .walletAccount(idByte:)`'s identical fixture pattern.
    private static func walletAccount(idByte: UInt8) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

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
    /// close the migration path back to Home. R8-T3 (#9): also fires `clearAbandonedNetworkSnapshot`
    /// fire-and-forget — asserted via a call-count spy, not just the path closing.
    @Test func migrationCoordFlowFinishedClosesPath() async {
        let clearAbandonedNetworkSnapshotCalls = LockIsolated<Int>(0)
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.path = Root.State.Path.migrationCoordFlow

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.clearAbandonedNetworkSnapshot = { _ in
                    clearAbandonedNetworkSnapshotCalls.withValue { $0 += 1 }
                }
            }

            store.send(.migrationCoordFlow(.flowFinished))
            await waitForRootStore { store.state.path == nil }

            #expect(store.state.path == nil)
            await waitForRootStore { clearAbandonedNetworkSnapshotCalls.withValue { $0 } == 1 }
            #expect(clearAbandonedNetworkSnapshotCalls.withValue { $0 } == 1)
        }
    }

    // MARK: - MOB-1496 (abandon reconciliation): external teardown cancels a stray Keystone run
    //
    // Mirrors the R8-T6 send-wait-hold release tests below for a DIFFERENT external-teardown
    // hazard: the final migration engine creates a Keystone commit's WHOLE run (preps and schedule
    // alike) the moment its PCZTs are built, and always resumes a stored non-terminal run on the next
    // attempt, ignoring any newer preview. `.flowFinished` normally follows the in-flow
    // `keystoneScanAbandoned`/resume machinery, which already clears `pendingKeystoneSigning` itself —
    // this is a defensive counterpart for the case where Root tears the flow down from OUTSIDE the
    // coordinator (e.g. the flow finished some other way while a ceremony was still stashed).

    @Test func migrationCoordFlowFinishedWithLivePendingKeystoneSigningCancelsStrayMigrationRun() async {
        let restartCalls = LockIsolated<[(AccountUUID, Bool)]>([])
        let account = Self.walletAccount(idByte: 40)
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.path = Root.State.Path.migrationCoordFlow
            initialState.$selectedWalletAccount.withLock { $0 = account }
            initialState.migrationCoordFlowState.pendingKeystoneSigning = MigrationCoordFlow.KeystoneSigningContext.planCommit

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.restartCurrentMigrationStep = { accountUUID, includeResidual in
                    restartCalls.withValue { $0.append((accountUUID, includeResidual)) }
                    return MigrationSchedule(transfers: [], estimatedDurationHours: 0)
                }
            }

            store.send(.migrationCoordFlow(.flowFinished))
            await waitForRootStore { store.state.path == nil }

            #expect(store.state.path == nil)
            await waitForRootStore { restartCalls.withValue { $0.count } == 1 }
            #expect(restartCalls.withValue { $0.count } == 1)
            #expect(restartCalls.withValue { $0.first?.0 } == account.id)
            #expect(restartCalls.withValue { $0.first?.1 } == false)
        }
    }

    /// MOB-1509: a migration notification for account B tapped while account A's Keystone ceremony
    /// is still live must cancel the stray run on A — the ceremony's RECORDED owner — not on B,
    /// which the tap path has already switched the selection to by the time the teardown runs.
    @Test func crossAccountNotificationTapCancelsStrayRunOnCeremonyOwner() async {
        let restartCalls = LockIsolated<[(AccountUUID, Bool)]>([])
        let accountA = Self.walletAccount(idByte: 44)
        let accountB = Self.walletAccount(idByte: 45)
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.appInitializationState = InitializationState.initialized
            initialState.path = Root.State.Path.migrationCoordFlow
            initialState.$selectedWalletAccount.withLock { $0 = accountA }
            initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }
            initialState.migrationCoordFlowState.pendingKeystoneSigning = MigrationCoordFlow.KeystoneSigningContext.planCommit
            initialState.migrationCoordFlowState.pendingKeystoneSigningAccountUUID = accountA.id

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.restartCurrentMigrationStep = { accountUUID, includeResidual in
                    restartCalls.withValue { $0.append((accountUUID, includeResidual)) }
                    return MigrationSchedule(transfers: [], estimatedDurationHours: 0)
                }
            }

            let accountBHex = Data(accountB.id.id).hexEncodedString()
            store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: accountBHex, isTorFailure: false))))
            await waitForRootStore { restartCalls.withValue { $0.count } >= 1 }
            await waitForRootStore { store.state.selectedWalletAccount == accountB }
            await waitForRootStore { store.state.path == Root.State.Path.migrationCoordFlow }

            // Exactly one cancel, on the OWNER: the switch's defensive teardown fires it for A and
            // clears the ceremony, so the flow-open's own cancel pass finds nothing left to cancel.
            #expect(restartCalls.withValue { $0.count } == 1)
            #expect(restartCalls.withValue { $0.first?.0 } == accountA.id)
            #expect(restartCalls.withValue { $0.first?.1 } == false)
            #expect(store.state.migrationCoordFlowState.pendingKeystoneSigning == nil)
        }
    }

    /// MOB-1509 (defensive): any account switch that fires while the migration coord flow is open
    /// tears the flow down first — cancelling a live ceremony on its recorded owner — instead of
    /// silently repointing the flow's live handlers at the newly selected account.
    @Test func walletAccountSwitchWithOpenMigrationFlowTearsDownAndCancelsOwnersCeremony() async {
        let restartCalls = LockIsolated<[(AccountUUID, Bool)]>([])
        let accountA = Self.walletAccount(idByte: 46)
        let accountB = Self.walletAccount(idByte: 47)
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.path = Root.State.Path.migrationCoordFlow
            initialState.$selectedWalletAccount.withLock { $0 = accountA }
            initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }
            initialState.migrationCoordFlowState.pendingKeystoneSigning = MigrationCoordFlow.KeystoneSigningContext.planCommit
            initialState.migrationCoordFlowState.pendingKeystoneSigningAccountUUID = accountA.id

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.restartCurrentMigrationStep = { accountUUID, includeResidual in
                    restartCalls.withValue { $0.append((accountUUID, includeResidual)) }
                    return MigrationSchedule(transfers: [], estimatedDurationHours: 0)
                }
            }

            store.send(.home(.walletAccountTapped(accountB)))
            await waitForRootStore { store.state.path == nil }
            await waitForRootStore { restartCalls.withValue { $0.count } == 1 }

            #expect(store.state.selectedWalletAccount == accountB)
            #expect(store.state.path == nil)
            #expect(store.state.migrationCoordFlowState.pendingKeystoneSigning == nil)
            #expect(store.state.migrationCoordFlowState.pendingKeystoneSigningAccountUUID == nil)
            #expect(restartCalls.withValue { $0.first?.0 } == accountA.id)
            #expect(restartCalls.withValue { $0.first?.1 } == false)
        }
    }

    /// MOB-1511 (W3): the Tor-failure notification's tap switches to the tapped account and
    /// surfaces the Tor-failure sheet over Home — it must NOT open the migration coord flow.
    @Test func torFailureNotificationTapChecksPromptInsteadOfOpeningFlow() async {
        let accountA = Self.walletAccount(idByte: 48)
        let accountB = Self.walletAccount(idByte: 49)
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.appInitializationState = InitializationState.initialized
            initialState.$selectedWalletAccount.withLock { $0 = accountA }
            initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                // The tapped account's background latch is armed — the check pass must present.
                $0.migrationManager.isPendingBackgroundTorPrompt = { _ in true }
            }

            let accountBHex = Data(accountB.id.id).hexEncodedString()
            store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: accountBHex, isTorFailure: true))))
            await waitForRootStore { store.state.selectedWalletAccount == accountB }
            await waitForRootStore { store.state.isTorFailurePromptPresented }

            #expect(store.state.selectedWalletAccount == accountB)
            #expect(store.state.isTorFailurePromptPresented)
            #expect(store.state.path == nil)
        }
    }

    /// Twin of the test above with no live ceremony (the ordinary case — `.flowFinished` following
    /// the Sending store's own successful exit, or any other flow-root close that never touched
    /// Keystone signing at all) — must never call `restartCurrentMigrationStep`.
    @Test func migrationCoordFlowFinishedWithNoPendingKeystoneSigningNeverCancelsMigrationRun() async {
        let restartCalls = LockIsolated<Int>(0)
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.path = Root.State.Path.migrationCoordFlow
            initialState.migrationCoordFlowState.pendingKeystoneSigning = nil

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.restartCurrentMigrationStep = { _, _ in
                    restartCalls.withValue { $0 += 1 }
                    return MigrationSchedule(transfers: [], estimatedDurationHours: 0)
                }
            }

            store.send(.migrationCoordFlow(.flowFinished))
            await waitForRootStore { store.state.path == nil }

            #expect(store.state.path == nil)
            // Let any async cancel effect settle before asserting its absence.
            try? await Task.sleep(nanoseconds: 300_000_000)
            #expect(restartCalls.withValue { $0 } == 0)
        }
    }

    /// MOB-1497: `.flowFinished` is the migration flow's teardown point — discards the account's
    /// network snapshot iff it is still provisional (never committed this run). Verified via a spy
    /// override on `clearProvisionalNetworkSnapshot` rather than real storage, matching this file's
    /// existing style of observing Root-level wiring through dependency spies.
    @Test func migrationCoordFlowFinishedClearsProvisionalNetworkSnapshot() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.path = Root.State.Path.migrationCoordFlow
            let clearProvisionalCalls = LockIsolated<[AccountUUID?]>([])

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.clearProvisionalNetworkSnapshot = { accountUUID in
                    clearProvisionalCalls.withValue { $0.append(accountUUID) }
                }
            }

            store.send(.migrationCoordFlow(.flowFinished))
            await waitForRootStore { store.state.path == nil }

            #expect(clearProvisionalCalls.value.count == 1)
        }
    }

    // MARK: - switchServerRequested -> teardown + path == .serverSwitch

    /// MOB-1497 (T4): the custom-server Tor sheet's "Switch Server" delegate reaches Root as
    /// `.migrationCoordFlow(.switchServerRequested)`. It must run the SAME teardown as `.flowFinished`
    /// — spied here via the same `clearProvisionalNetworkSnapshot` / `clearAbandonedNetworkSnapshot`
    /// closures the `flowFinished` tests spy — but land on Server Setup (`path == .serverSwitch`)
    /// instead of closing to Home.
    @Test func migrationCoordFlowSwitchServerRequestedTearsDownAndRoutesToServerSetup() async {
        let clearProvisionalCalls = LockIsolated<[AccountUUID?]>([])
        let clearAbandonedNetworkSnapshotCalls = LockIsolated<Int>(0)
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.path = Root.State.Path.migrationCoordFlow

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.clearProvisionalNetworkSnapshot = { accountUUID in
                    clearProvisionalCalls.withValue { $0.append(accountUUID) }
                }
                $0.migrationManager.clearAbandonedNetworkSnapshot = { _ in
                    clearAbandonedNetworkSnapshotCalls.withValue { $0 += 1 }
                }
            }

            store.send(.migrationCoordFlow(.switchServerRequested))
            await waitForRootStore { store.state.path == Root.State.Path.serverSwitch }

            // Routed to Server Setup, not closed to Home.
            #expect(store.state.path == Root.State.Path.serverSwitch)
            // Same teardown as `.flowFinished`: provisional cleared once, abandoned cleared once.
            #expect(clearProvisionalCalls.value.count == 1)
            await waitForRootStore { clearAbandonedNetworkSnapshotCalls.withValue { $0 } == 1 }
            #expect(clearAbandonedNetworkSnapshotCalls.withValue { $0 } == 1)
        }
    }

    // MARK: - MOB-1513 (H3 guard): setMigrationFlowPresented disarmed at every close/replace site
    //
    // `MigrationCoordFlow.State.presentedMigrationFlowAccountUUID` is the account THIS flow
    // instance recorded as its owner at `.onAppear` (see `MigrationCoordFlowTests`'s coverage of
    // the arm side). Every one of Root's migration-flow close/replace sites must disarm
    // `migrationManager.setMigrationFlowPresented` for exactly THAT recorded account — never
    // whatever `state.selectedWalletAccount` reads at close time — or the H3 guard would strand
    // permanently true for an account whose flow already closed. Verified against HEAD: the sites
    // turned out to be FOUR, not the three the pre-guard doc comment named — `tearDownMigrationCoordFlow`
    // covers three (`.flowFinished`/`.switchServerRequested`/the inline `.walletAccountTapped`
    // teardown) via one shared call; the Sending `.viewTransaction` delegate and
    // `openMigrationCoordFlow` (the notification-tap deep link) each close/replace the path WITHOUT
    // routing through that helper, so each disarms independently.

    /// `.flowFinished` (via the shared `tearDownMigrationCoordFlow` helper) disarms the signal for
    /// the RECORDED owner account.
    @Test func migrationCoordFlowFinishedDisarmsMigrationFlowPresentedSignalForRecordedAccount() async {
        let setMigrationFlowPresentedCalls = LockIsolated<[(AccountUUID?, Bool)]>([])
        let account = Self.walletAccount(idByte: 56)
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.path = Root.State.Path.migrationCoordFlow
            initialState.migrationCoordFlowState.presentedMigrationFlowAccountUUID = account.id

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.setMigrationFlowPresented = { accountUUID, isPresented in
                    setMigrationFlowPresentedCalls.withValue { $0.append((accountUUID, isPresented)) }
                }
            }

            store.send(.migrationCoordFlow(.flowFinished))
            await waitForRootStore { store.state.path == nil }
            await waitForRootStore { setMigrationFlowPresentedCalls.value.count == 1 }

            #expect(setMigrationFlowPresentedCalls.value.count == 1)
            #expect(setMigrationFlowPresentedCalls.value.first?.0 == account.id)
            #expect(setMigrationFlowPresentedCalls.value.first?.1 == false)
        }
    }

    /// `.switchServerRequested` (the SAME shared helper, different downstream destination) disarms
    /// identically.
    @Test func migrationCoordFlowSwitchServerRequestedDisarmsMigrationFlowPresentedSignalForRecordedAccount() async {
        let setMigrationFlowPresentedCalls = LockIsolated<[(AccountUUID?, Bool)]>([])
        let account = Self.walletAccount(idByte: 57)
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.path = Root.State.Path.migrationCoordFlow
            initialState.migrationCoordFlowState.presentedMigrationFlowAccountUUID = account.id

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.setMigrationFlowPresented = { accountUUID, isPresented in
                    setMigrationFlowPresentedCalls.withValue { $0.append((accountUUID, isPresented)) }
                }
            }

            store.send(.migrationCoordFlow(.switchServerRequested))
            await waitForRootStore { store.state.path == Root.State.Path.serverSwitch }
            await waitForRootStore { setMigrationFlowPresentedCalls.value.count == 1 }

            #expect(setMigrationFlowPresentedCalls.value.count == 1)
            #expect(setMigrationFlowPresentedCalls.value.first?.0 == account.id)
            #expect(setMigrationFlowPresentedCalls.value.first?.1 == false)
        }
    }

    /// The KEY account-keying test: an account switch while the flow is open (the inline teardown
    /// inside `.home(.walletAccountTapped)`, ALSO routed through `tearDownMigrationCoordFlow`) must
    /// disarm the signal for the OLD (recorded) account — never the newly-tapped one — even though
    /// `state.selectedWalletAccount` has not been reassigned yet at the moment the helper runs.
    /// Mirrors `walletAccountSwitchWithOpenMigrationFlowTearsDownAndCancelsOwnersCeremony`'s existing
    /// "recorded owner, not selected-at-close" precedent for `pendingKeystoneSigningAccountUUID`.
    @Test func walletAccountSwitchWithOpenMigrationFlowDisarmsMigrationFlowPresentedSignalForOldAccountOnly() async {
        let setMigrationFlowPresentedCalls = LockIsolated<[(AccountUUID?, Bool)]>([])
        let accountA = Self.walletAccount(idByte: 58)
        let accountB = Self.walletAccount(idByte: 59)
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.path = Root.State.Path.migrationCoordFlow
            initialState.$selectedWalletAccount.withLock { $0 = accountA }
            initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }
            initialState.migrationCoordFlowState.presentedMigrationFlowAccountUUID = accountA.id

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.setMigrationFlowPresented = { accountUUID, isPresented in
                    setMigrationFlowPresentedCalls.withValue { $0.append((accountUUID, isPresented)) }
                }
            }

            store.send(.home(.walletAccountTapped(accountB)))
            await waitForRootStore { store.state.path == nil }
            await waitForRootStore { setMigrationFlowPresentedCalls.value.count == 1 }

            #expect(store.state.selectedWalletAccount == accountB)
            #expect(setMigrationFlowPresentedCalls.value.count == 1)
            #expect(setMigrationFlowPresentedCalls.value.first?.0 == accountA.id)
            #expect(setMigrationFlowPresentedCalls.value.first?.1 == false)
        }
    }

    /// The Sending `.viewTransaction` delegate closes `state.path` WITHOUT routing through
    /// `tearDownMigrationCoordFlow` (see that case's own doc in `RootCoordinator.swift` for why —
    /// View Transaction is reached well past commit) — it must still disarm the signal
    /// independently, or the flag would strand permanently true for this account.
    @Test func sendingViewTransactionDelegateDisarmsMigrationFlowPresentedSignalForRecordedAccount() async {
        let setMigrationFlowPresentedCalls = LockIsolated<[(AccountUUID?, Bool)]>([])
        let account = Self.walletAccount(idByte: 60)
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.path = Root.State.Path.migrationCoordFlow
            initialState.migrationCoordFlowState.presentedMigrationFlowAccountUUID = account.id
            let sendingState = MigrationSending.State(phase: .success, txId: "stub-tx-id")
            initialState.migrationCoordFlowState.path.append(.sending(sendingState))

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.setMigrationFlowPresented = { accountUUID, isPresented in
                    setMigrationFlowPresentedCalls.withValue { $0.append((accountUUID, isPresented)) }
                }
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
            await waitForRootStore { setMigrationFlowPresentedCalls.value.count == 1 }

            #expect(setMigrationFlowPresentedCalls.value.count == 1)
            #expect(setMigrationFlowPresentedCalls.value.first?.0 == account.id)
            #expect(setMigrationFlowPresentedCalls.value.first?.1 == false)
        }
    }

    /// `openMigrationCoordFlow` (the notification-tap deep link) wholesale-REPLACES
    /// `migrationCoordFlowState` with a fresh `.initial` and can fire while the flow is ALREADY
    /// open (R8-T6 already established this exact hazard class for the send-wait-hold flag — see
    /// `notificationTapTeardownReleasesLiveSendWaitHoldAndUnfencesRetryStart` above, which this test
    /// mirrors). It must disarm the OLD recorded account's signal BEFORE the reset discards the
    /// only record of which account it was armed for — otherwise the flag strands permanently true.
    @Test func notificationTapWhileFlowAlreadyOpenDisarmsMigrationFlowPresentedSignalForOldAccount() async {
        let setMigrationFlowPresentedCalls = LockIsolated<[(AccountUUID?, Bool)]>([])
        let account = Self.walletAccount(idByte: 61)
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.appInitializationState = InitializationState.initialized
            initialState.path = Root.State.Path.migrationCoordFlow
            initialState.$selectedWalletAccount.withLock { $0 = account }
            initialState.migrationCoordFlowState.presentedMigrationFlowAccountUUID = account.id
            initialState.migrationCoordFlowState.path.append(
                .sending(MigrationSending.State(totalCount: 1, entersViaSendNow: true))
            )

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.setMigrationFlowPresented = { accountUUID, isPresented in
                    setMigrationFlowPresentedCalls.withValue { $0.append((accountUUID, isPresented)) }
                }
            }

            store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: nil, isTorFailure: false))))
            await waitForRootStore { store.state.migrationCoordFlowState.path.isEmpty }
            await waitForRootStore { setMigrationFlowPresentedCalls.value.count == 1 }

            #expect(store.state.path == Root.State.Path.migrationCoordFlow)
            #expect(setMigrationFlowPresentedCalls.value.count == 1)
            #expect(setMigrationFlowPresentedCalls.value.first?.0 == account.id)
            #expect(setMigrationFlowPresentedCalls.value.first?.1 == false)
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

    // MARK: - R9-T5 (finding 7): launch-time clear of abandoned migration snapshots

    /// The WARM re-init shape: `walletAccounts`/`selectedWalletAccount` are already populated
    /// (pre-seeded below) before `.initialSetups` fires, e.g. a `willEnterForeground` re-entry
    /// while unprepared/locked, or a `walletConfigChanged` re-init — both re-run `.initialSetups`
    /// later in an ALREADY-running process, not a fresh one. The launch path must fan
    /// `clearAbandonedNetworkSnapshot` out over EVERY candidate account (selected first, then the
    /// rest of `walletAccounts`, deduped — the same set `reconcile()` itself fans over), AFTER
    /// `reconcile()` has completed. `clearAbandonedCallsHappenedAfterReconcile` is flipped false
    /// the instant a clear call is observed with the reconcile counter still at 0, so the ordering
    /// assertion is pinned at the moment of the call rather than inferred from polling timing.
    /// Contrast with `loadedWalletAccountsClearsAbandonedSnapshotsOnAColdLaunchWhereInitialSetupsFoundNoAccountsYet`
    /// below, which models a genuine COLD launch instead (nothing pre-seeded).
    @Test func initialSetupsClearsAbandonedSnapshotsForEveryCandidateAccountAfterReconcile() async {
        let reconcileCalls = LockIsolated<Int>(0)
        let clearAbandonedCalls = LockIsolated<[AccountUUID]>([])
        let clearAbandonedCallsHappenedAfterReconcile = LockIsolated<Bool>(true)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let selected = Self.walletAccount(idByte: 1)
            let second = Self.walletAccount(idByte: 2)

            let initialState = Root.State.initial
            initialState.$selectedWalletAccount.withLock { $0 = selected }
            initialState.$walletAccounts.withLock { $0 = [selected, second] }

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.migrationManager.reconcile = {
                    reconcileCalls.withValue { $0 += 1 }
                }
                $0.migrationManager.clearAbandonedNetworkSnapshot = { accountUUID in
                    if reconcileCalls.withValue({ $0 }) == 0 {
                        clearAbandonedCallsHappenedAfterReconcile.withValue { $0 = false }
                    }
                    if let accountUUID {
                        clearAbandonedCalls.withValue { $0.append(accountUUID) }
                    }
                }
            }

            store.send(.initialization(.initialSetups))
            await waitForRootStore { clearAbandonedCalls.withValue { $0.count } == 2 }

            #expect(reconcileCalls.withValue { $0 } == 1)
            #expect(Set(clearAbandonedCalls.value) == Set([selected.id, second.id]))
            #expect(clearAbandonedCallsHappenedAfterReconcile.value == true)
        }
    }

    /// R9-T5 fix (final-review IMPORTANT-1): the genuine COLD-launch shape — unlike the test above,
    /// `walletAccounts`/`selectedWalletAccount` are NOT pre-seeded before `.initialSetups` fires. A
    /// fresh process starts both nil/empty (`Root.State.initial`'s own `@Shared` defaults); they're
    /// populated only once `.loadedWalletAccounts` lands, dispatched from deep inside
    /// `.initializeSDK`'s effect after `sdkSynchronizer.walletAccounts()` succeeds — i.e. well AFTER
    /// `.initialSetups` already fired and its own `.clearAbandonedMigrationSnapshots` send found an
    /// empty candidate list. Driving `.loadedWalletAccounts` directly afterward (mirroring the real
    /// send `.initializeSDK`'s effect makes) is what actually fans the clear out once accounts
    /// exist. FAILS on the pre-fix parent (a single send site chained off `.initialSetups`, which
    /// never sees a non-empty candidate list in this shape — see IMPORTANT-1's own failure walk).
    @Test func loadedWalletAccountsClearsAbandonedSnapshotsOnAColdLaunchWhereInitialSetupsFoundNoAccountsYet() async {
        let reconcileCalls = LockIsolated<Int>(0)
        let clearAbandonedCalls = LockIsolated<[AccountUUID]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let first = Self.walletAccount(idByte: 1)
            let second = Self.walletAccount(idByte: 2)

            // A genuine cold launch: nothing pre-seeded — `Root.State.initial` starts with no
            // selected account and no wallet accounts, exactly like a fresh process.
            let initialState = Root.State.initial

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.migrationManager.reconcile = {
                    reconcileCalls.withValue { $0 += 1 }
                }
                $0.migrationManager.clearAbandonedNetworkSnapshot = { accountUUID in
                    if let accountUUID {
                        clearAbandonedCalls.withValue { $0.append(accountUUID) }
                    }
                }
                // `.loadedWalletAccounts` (driven directly below) auto-selects the first `.zcash`
                // vendor account when none is selected yet, which also populates
                // `state.zashiWalletAccount` — its own returned effect then sends `.loadContacts`,
                // which reads that account and calls this member. Not `baseNoOpDependencies`'
                // concern (unrelated to migration); stubbed locally, matching this file's existing
                // per-test override convention.
                $0.addressBook.allLocalContacts = { _ in
                    (AddressBookContacts.empty, AddressBookClient.RemoteStoreResult.success)
                }
            }

            // Mirrors a cold `didFinishLaunching` reaching `.initialSetups` — accounts are still
            // empty/nil at this point, so its own `.clearAbandonedMigrationSnapshots` send fans
            // over an empty candidate list.
            store.send(.initialization(.initialSetups))
            await waitForRootStore { reconcileCalls.withValue { $0 } == 1 }
            // Let the (empty-list) fan-out effect settle before checking it found nothing — same
            // "let it settle" idiom as `clearAbandonedMigrationSnapshotsNoOpsWhileMigrationFlowIsOpen`
            // below.
            try? await Task.sleep(nanoseconds: 300_000_000)
            #expect(clearAbandonedCalls.withValue { $0 } == [])

            // The SDK has now prepared and reported its account list — mirrors the real send
            // `.initializeSDK`'s effect makes (`RootInitialization.swift`, inside
            // `sdkSynchronizer.prepareWith`/`walletAccounts()`'s success continuation).
            store.send(.initialization(.loadedWalletAccounts([first, second])))
            await waitForRootStore { clearAbandonedCalls.withValue { $0.count } == 2 }

            #expect(Set(clearAbandonedCalls.value) == Set([first.id, second.id]))
        }
    }

    /// Guard: when the migration flow is open (`state.path == .migrationCoordFlow`) at the moment
    /// `.clearAbandonedMigrationSnapshots` fires, it must NOT call `clearAbandonedNetworkSnapshot`
    /// at all — see that action's reducer-arm doc for the launch-side race (a migration-notification
    /// tap opening the flow mid-cold-start) this guard closes. Sent directly rather than via
    /// `.initialSetups` to isolate the guard from the rest of the launch chain.
    @Test func clearAbandonedMigrationSnapshotsNoOpsWhileMigrationFlowIsOpen() async {
        let clearAbandonedCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.path = Root.State.Path.migrationCoordFlow
            initialState.$selectedWalletAccount.withLock { $0 = Self.walletAccount(idByte: 1) }

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.clearAbandonedNetworkSnapshot = { _ in
                    clearAbandonedCalls.withValue { $0 += 1 }
                }
            }

            store.send(.initialization(.clearAbandonedMigrationSnapshots))
            // Let any (wrongly-fired) effect settle before asserting its absence — same idiom as
            // `notificationTapTeardownWithNoHoldActiveNeverNudgesGate` above.
            try? await Task.sleep(nanoseconds: 300_000_000)

            #expect(store.state.path == Root.State.Path.migrationCoordFlow)
            #expect(clearAbandonedCalls.withValue { $0 } == 0)
        }
    }

    // MARK: - View Transaction (Sending delegate)

    /// The migration Sending screen's `.viewTransaction` delegate carries only a bare
    /// `txId: String` — never a real `TransactionState` the existing transaction-detail plumbing
    /// (`TransactionDetails.State.transaction`, non-optional) could open, and the app has no
    /// by-txid lookup to build one from. Root's v1 handling (see the doc comment on this case in
    /// `RootCoordinator.swift`) treats it as a flow close rather than opening a broken/empty
    /// detail screen, pending a by-txid transaction lookup (MOB-1458).
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

            // R8-T5 (S4-c): a nil/absent payload account routes exactly as before S4.
            store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: nil, isTorFailure: false))))
            await waitForRootStore { store.state.path == Root.State.Path.migrationCoordFlow }

            #expect(store.state.path == Root.State.Path.migrationCoordFlow)
            #expect(store.state.migrationCoordFlowState.mode == nil)
            #expect(store.state.migrationCoordFlowState.path.isEmpty)
            #expect(store.state.pendingMigrationDeepLink == false)
            #expect(store.state.pendingMigrationDeepLinkAccountUUID == nil)
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

            // R8-T5 (S4): the stash carries an account too — replayed below.
            let taggedAccountUUID = Data(Self.walletAccount(idByte: 9).id.id).hexEncodedString()
            store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: taggedAccountUUID, isTorFailure: false))))
            await waitForRootStore { store.state.pendingMigrationDeepLink == true }

            #expect(store.state.pendingMigrationDeepLink == true)
            #expect(store.state.pendingMigrationDeepLinkAccountUUID == taggedAccountUUID)
            #expect(store.state.path == nil)

            store.send(.initialization(.checkBackupPhraseValidation))
            await waitForRootStore { store.state.path == Root.State.Path.migrationCoordFlow }

            #expect(store.state.path == Root.State.Path.migrationCoordFlow)
            #expect(store.state.pendingMigrationDeepLink == false)
            #expect(store.state.pendingMigrationDeepLinkAccountUUID == nil)
        }
    }

    /// R8-T5 (S4-b): a tapped notification whose payload account differs from the currently
    /// selected one must switch FIRST — via the house account-switch action (`.home
    /// (.walletAccountTapped(_:))`, the SAME one `WalletAccountsSheet`'s tap uses) — THEN open the
    /// migration flow.
    ///
    /// This file uses a plain `Store` (not `TestStore`) throughout — per its own header doc, `Root`'s
    /// heavy init effects make exhaustive `TestStore` assertion impractical. That same choice also
    /// turns out to be load-bearing here for a different reason: `TestStore<State: Equatable,
    /// Action>` requires `Root.State: Equatable`, which it is not (confirmed against HEAD — adding
    /// that conformance is a large, unrelated change well outside this task's "notification compose
    /// + tap routing ONLY" scope). So this test asserts the OUTCOME (both the switch and the route
    /// landed) via the same polling idiom every other test in this file uses; the ORDER guarantee
    /// itself is structural, not empirical — `migrationNotificationTappedRoutingEffect`
    /// (`RootInitialization.swift`) dispatches `.home(.walletAccountTapped(_:))` and
    /// `.initialization(.migrationNotificationRoute)` via `.concatenate(...)`, which — per
    /// `Effect.concatenate`'s own contract — only starts the second `.send` once the first action's
    /// reducer pass (here, the synchronous `@Shared` write) has been fully applied, verifiable by
    /// inspection of that function.
    @Test func migrationNotificationTappedWithDifferentAccountSwitchesBeforeRouting() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let selected = Self.walletAccount(idByte: 1)
            let target = Self.walletAccount(idByte: 2)

            var initialState = Root.State.initial
            initialState.appInitializationState = InitializationState.initialized
            initialState.$selectedWalletAccount.withLock { $0 = selected }
            initialState.$walletAccounts.withLock { $0 = [selected, target] }

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
            }

            store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: Data(target.id.id).hexEncodedString(), isTorFailure: false))))
            await waitForRootStore { store.state.path == Root.State.Path.migrationCoordFlow }

            #expect(store.state.path == Root.State.Path.migrationCoordFlow)
            #expect(store.state.selectedWalletAccount == target)
        }
    }

    /// R8-T5 (S4-b, negative case): a tapped notification whose payload account MATCHES the
    /// already-selected account must NOT dispatch a switch — routes immediately with the selection
    /// untouched, exactly like a nil payload does.
    @Test func migrationNotificationTappedWithSameAccountAsSelectedDoesNotSwitch() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let selected = Self.walletAccount(idByte: 1)
            var initialState = Root.State.initial
            initialState.appInitializationState = InitializationState.initialized
            initialState.$selectedWalletAccount.withLock { $0 = selected }
            initialState.$walletAccounts.withLock { $0 = [selected] }

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
            }

            store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: Data(selected.id.id).hexEncodedString(), isTorFailure: false))))
            await waitForRootStore { store.state.path == Root.State.Path.migrationCoordFlow }

            #expect(store.state.path == Root.State.Path.migrationCoordFlow)
            #expect(store.state.selectedWalletAccount == selected)
        }
    }

    /// R8-T5 (S4-c edge): a payload account that doesn't resolve to any of `walletAccounts` (stale/
    /// removed account) must degrade exactly like an absent payload — route immediately, selection
    /// untouched — rather than getting stuck or crashing on the lookup.
    @Test func migrationNotificationTappedWithUnresolvableAccountRoutesWithoutSwitching() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let selected = Self.walletAccount(idByte: 1)
            var initialState = Root.State.initial
            initialState.appInitializationState = InitializationState.initialized
            initialState.$selectedWalletAccount.withLock { $0 = selected }
            initialState.$walletAccounts.withLock { $0 = [selected] }

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
            }

            store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: "not-a-real-account", isTorFailure: false))))
            await waitForRootStore { store.state.path == Root.State.Path.migrationCoordFlow }

            #expect(store.state.path == Root.State.Path.migrationCoordFlow)
            #expect(store.state.selectedWalletAccount == selected)
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

    // MARK: - R8-T6 fix-wave (Critical-1): external teardown must release the send-wait hold

    /// C1-a (red-first): a live `.sending(.waiting)` element — its hold flag set via
    /// `MigrationSendingStore`'s OWN real `onAppear` -> `.sendNowGateResolved(.waitUntil(...))`
    /// path, not a hand-poked `@Shared` write — sits on the migration path when a migration
    /// notification tap arrives. The SAME notification-tap teardown route
    /// `migrationNotificationTappedOnInitializedStateRoutesImmediately` above exercises
    /// (`migrationNotificationTapped` -> `openMigrationCoordFlow`) must release the leaked hold:
    /// the flag clears, `refreshMigrationSyncGate()` fires (identical semantics to the store's own
    /// Cancel), and a SUBSEQUENT `.retryStart` is no longer fenced. FAILS against HEAD 1c828465 —
    /// `openMigrationCoordFlow` resets the flow with no flag release, so the flag stays stranded
    /// true and the following `.retryStart` silently re-defers forever.
    @Test func notificationTapTeardownReleasesLiveSendWaitHoldAndUnfencesRetryStart() async {
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let startCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.migrationSendWaitActive)) var migrationSendWaitActive: Bool = false
            $migrationSendWaitActive.withLock { $0 = false }

            let target = Date().addingTimeInterval(600)
            let preparedState: SynchronizerState = {
                var state = SynchronizerState.zero
                state.syncStatus = SyncStatus.upToDate
                return state
            }()

            var initialState = Root.State.initial
            initialState.appInitializationState = InitializationState.initialized
            initialState.path = Root.State.Path.migrationCoordFlow
            initialState.migrationCoordFlowState.path.append(
                .sending(MigrationSending.State(totalCount: 1, entersViaSendNow: true))
            )

            let sendingId = try? #require(initialState.migrationCoordFlowState.path.ids.last)
            guard let sendingId else {
                Issue.record("Expected a sending element id on the migration path")
                return
            }

            let clock = TestClock()
            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.continuousClock = clock
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.migrationManager.sendGate = { .waitUntil(target) }
                $0.migrationManager.refreshMigrationSyncGate = {
                    refreshMigrationSyncGateCalls.withValue { $0 += 1 }
                }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { preparedState },
                    start: { _ in startCalls.withValue { $0.append(true) } },
                    isSyncing: { true }
                )
                $0.sdkSynchronizer.isMigrationSyncBlocked = { false }
            }

            // Drive the REAL Sending store's onAppear: it stops sync, reads the gate
            // (`.waitUntil`), enters `.waiting`, and sets the hold flag via its own
            // `setSendWaitActive(true)` — the store's real path, not a hand-poked flag.
            store.send(.migrationCoordFlow(.path(.element(id: sendingId, action: .sending(.onAppear)))))
            await waitForRootStore { migrationSendWaitActive == true }
            #expect(migrationSendWaitActive == true)

            // The notification-tap teardown route.
            store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: nil, isTorFailure: false))))
            await waitForRootStore { store.state.migrationCoordFlowState.path.isEmpty }

            #expect(store.state.path == Root.State.Path.migrationCoordFlow)
            #expect(store.state.migrationCoordFlowState.path.isEmpty)
            await waitForRootStore { migrationSendWaitActive == false }
            #expect(migrationSendWaitActive == false)
            await waitForRootStore { refreshMigrationSyncGateCalls.withValue { $0 } == 1 }
            #expect(refreshMigrationSyncGateCalls.withValue { $0 } == 1)

            // A subsequent `.retryStart` must no longer be fenced — start proceeds. (Not pinned to
            // exactly one call: `migrationStoppedSyncForBroadcast` is still `true` here — nothing
            // in this fix clears it, by design, matching `.waitCancelTapped`'s own semantics — so
            // this successful `.retryStart`'s OWN `.registerForSynchronizersUpdate` seed-reads
            // `isMigrationSyncBlocked()` and, seeing it still set, legitimately replays a resume
            // once more via the PRE-EXISTING `.migrationSyncGateChanged` mechanism above; that
            // second start is orthogonal to this fix and out of scope here — what matters is that
            // the fence no longer silently swallows the trigger.)
            store.send(.initialization(.retryStart))
            await waitForRootStore { startCalls.withValue { !$0.isEmpty } }
            #expect(startCalls.withValue { !$0.isEmpty })
        }
    }

    /// C1-b: the SAME teardown route with the hold flag NOT set — the release helper must be a
    /// pure no-op (no nudge call). Guards against a naive implementation that nudges
    /// unconditionally on every teardown regardless of whether a hold was ever live.
    @Test func notificationTapTeardownWithNoHoldActiveNeverNudgesGate() async {
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.migrationSendWaitActive)) var migrationSendWaitActive: Bool = false
            $migrationSendWaitActive.withLock { $0 = false }

            var initialState = Root.State.initial
            initialState.appInitializationState = InitializationState.initialized
            // Poison the pre-existing flow state so the reset itself is still observable, same as
            // `migrationNotificationTappedOnInitializedStateRoutesImmediately` above.
            initialState.migrationCoordFlowState.mode = MigrationMode.immediate
            initialState.migrationCoordFlowState.path.append(.complete(MigrationComplete.State()))

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.refreshMigrationSyncGate = {
                    refreshMigrationSyncGateCalls.withValue { $0 += 1 }
                }
            }

            store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: nil, isTorFailure: false))))
            await waitForRootStore { store.state.migrationCoordFlowState.path.isEmpty }

            #expect(store.state.path == Root.State.Path.migrationCoordFlow)
            #expect(migrationSendWaitActive == false)
            // Let any async nudge effect settle before asserting its absence.
            try? await Task.sleep(nanoseconds: 300_000_000)
            #expect(refreshMigrationSyncGateCalls.withValue { $0 } == 0)
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
    values.migrationManager.migrationMode = { _ in nil }
    values.migrationManager.setMigrationMode = { _, _ in }
    values.migrationManager.setManualDelivery = { _, _ in }
    values.migrationManager.setNetworkPrivacyOptions = { _ in }
    values.migrationManager.formNetworkSnapshot = { _ in }
    values.migrationManager.markNetworkSnapshotCommitted = { _ in }
    values.migrationManager.clearProvisionalNetworkSnapshot = { _ in }
    values.migrationManager.setMigrationFlowPresented = { _, _ in }
    values.migrationManager.acknowledgeComplete = { _ in }
    values.migrationManager.reconcile = { }
    values.migrationManager.clearAbandonedNetworkSnapshot = { _ in }
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
