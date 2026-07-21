//
//  RootTorFailurePromptTests.swift
//  zodlTests
//
//  Covers MOB-1497 (T6)'s Root-level hosting of the "Couldn't Connect to Tor" sheet
//  (Features/Root/RootCoordinator.swift + RootInitialization.swift): the foreground presentation
//  gate (`.checkMigrationTorFailurePrompt`), the once-per-foreground latch and its reset on
//  background entry, and the two button effects (`.torFailurePrompt(.delegate)`) — clear the latch,
//  optionally override Tor off, run ONE foreground broadcast attempt, and (on a Tor-class retry
//  failure) re-arm the latch and re-present.
//
//  `.serialized` + plain `Store` (not `TestStore`) with `withDependencies` overrides and
//  `LockIsolated` spies + polling — the same live-context idiom as `RootMigrationBackgroundTests`/
//  `RootMigrationRoutingTests` (constructing `Root.State` reads the process-global
//  `@Shared(.inMemory(.selectedWalletAccount))` key). `isPendingBackgroundTorPrompt` is overridden
//  explicitly per test — un-overridden it would hit the live `UserDefaults` impl.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RootTorFailurePromptTests {
    private static func walletAccount(idByte: UInt8 = 1) -> WalletAccount {
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

    /// `Root.State.initial` with a selected account stashed and `.initialized` — the Home-visible
    /// baseline every T6 test starts from (path == nil, no covers, nothing presented, latch clear).
    private static func homeState() -> Root.State {
        var state = Root.State.initial
        state.appInitializationState = InitializationState.initialized
        state.$selectedWalletAccount.withLock { $0 = walletAccount() }
        return state
    }

    // MARK: - Foreground presentation gate

    /// Home visible + the account's background Tor-failure latch armed -> present, and mark the
    /// once-per-foreground latch consumed.
    @Test func foregroundCheckPresentsWhenHomeVisibleAndFlagArmed() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.homeState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.isPendingBackgroundTorPrompt = { _ in true }
            }

            store.send(.checkMigrationTorFailurePrompt)

            #expect(store.state.isTorFailurePromptPresented)
            #expect(store.state.didOfferTorFailurePromptThisForeground)
        }
    }

    /// Latch NOT armed -> nothing presented, nothing consumed.
    @Test func foregroundCheckDoesNotPresentWhenFlagNotArmed() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.homeState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.isPendingBackgroundTorPrompt = { _ in false }
            }

            store.send(.checkMigrationTorFailurePrompt)

            #expect(!store.state.isTorFailurePromptPresented)
            #expect(!store.state.didOfferTorFailurePromptThisForeground)
        }
    }

    /// A Root path pushed (Home not bare) blocks presentation — and must NOT consume the latch, so a
    /// later foreground with Home visible still presents (proven by
    /// `foregroundCheckPresentsWhenHomeVisibleAndFlagArmed`).
    @Test func foregroundCheckDoesNotPresentWhenPathPushedAndLeavesLatchUnconsumed() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Self.homeState()
            initialState.path = Root.State.Path.settings

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.isPendingBackgroundTorPrompt = { _ in true }
            }

            store.send(.checkMigrationTorFailurePrompt)

            #expect(!store.state.isTorFailurePromptPresented)
            #expect(!store.state.didOfferTorFailurePromptThisForeground)
        }
    }

    /// The Server Setup full-screen cover being up blocks presentation.
    @Test func foregroundCheckDoesNotPresentWhenServerSetupCoverVisible() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Self.homeState()
            initialState.serverSetupViewBinding = true

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.isPendingBackgroundTorPrompt = { _ in true }
            }

            store.send(.checkMigrationTorFailurePrompt)

            #expect(!store.state.isTorFailurePromptPresented)
        }
    }

    /// No selected account -> nothing to prompt for.
    @Test func foregroundCheckDoesNotPresentWhenNoSelectedAccount() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            initialState.appInitializationState = InitializationState.initialized

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.isPendingBackgroundTorPrompt = { _ in true }
            }

            store.send(.checkMigrationTorFailurePrompt)

            #expect(!store.state.isTorFailurePromptPresented)
        }
    }

    /// Already presented -> the gate no-ops (no double-present, latch untouched).
    @Test func foregroundCheckDoesNotRePresentWhenAlreadyPresented() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Self.homeState()
            initialState.isTorFailurePromptPresented = true

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.isPendingBackgroundTorPrompt = { _ in true }
            }

            store.send(.checkMigrationTorFailurePrompt)

            #expect(store.state.isTorFailurePromptPresented)
            #expect(!store.state.didOfferTorFailurePromptThisForeground)
        }
    }

    // MARK: - Once-per-foreground latch

    /// After presenting once and swipe-dismissing, a SECOND foreground check in the SAME foreground
    /// must NOT re-present (the latch is consumed) — even though the account's latch is still armed.
    @Test func oncePerForegroundLatchBlocksReCheckAfterSwipeDismiss() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.homeState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.isPendingBackgroundTorPrompt = { _ in true }
            }

            // First foreground check presents.
            store.send(.checkMigrationTorFailurePrompt)
            #expect(store.state.isTorFailurePromptPresented)
            #expect(store.state.didOfferTorFailurePromptThisForeground)

            // Swipe-dismiss: sheet down, latch consumed stays true.
            store.send(.torFailurePromptPresentationChanged(false))
            #expect(!store.state.isTorFailurePromptPresented)
            #expect(store.state.didOfferTorFailurePromptThisForeground)

            // Second check in the same foreground: blocked by the once-per-foreground latch.
            store.send(.checkMigrationTorFailurePrompt)
            #expect(!store.state.isTorFailurePromptPresented)
        }
    }

    /// Backgrounding resets the once-per-foreground latch, so the NEXT foreground presents again.
    @Test func backgroundEntryResetsLatchSoNextForegroundPresentsAgain() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Self.homeState()
            // Simulate "already offered + dismissed this foreground".
            initialState.didOfferTorFailurePromptThisForeground = true

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.isPendingBackgroundTorPrompt = { _ in true }
            }

            // Still blocked before backgrounding.
            store.send(.checkMigrationTorFailurePrompt)
            #expect(!store.state.isTorFailurePromptPresented)

            // Background entry resets the latch.
            store.send(.initialization(.appDelegate(.didEnterBackground)))
            #expect(!store.state.didOfferTorFailurePromptThisForeground)

            // Next foreground presents again.
            store.send(.checkMigrationTorFailurePrompt)
            #expect(store.state.isTorFailurePromptPresented)
        }
    }

    // MARK: - Button effects

    /// "Continue without Tor": dismiss, clear the latch, turn Tor off for the run, and run exactly one
    /// foreground broadcast attempt.
    @Test func continueWithoutTorClearsLatchOverridesTorOffAndRunsOneAttempt() async {
        let accountUUID = Self.walletAccount().id
        let overrideTorCalls = LockIsolated<[(AccountUUID?, Bool)]>([])
        let setPendingCalls = LockIsolated<[Bool]>([])
        let executeCalls = LockIsolated<Int>(0)
        // Fix-wave finding (review IMPORTANT): the attempt must stop an in-flight sync before
        // broadcasting — mirrors `MigrationSendingStore.executeNextTransfer`'s own spy idiom
        // (`isSyncing: { true }` so the guard inside `stopSyncBeforeMigrationBroadcast()` passes,
        // spying on `stop` to prove it actually ran).
        let stopSyncCalls = LockIsolated<Int>(0)
        // A `.success` result needs no gate nudge — the SDK's own gate transition covers the resume.
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Self.homeState()
            initialState.isTorFailurePromptPresented = true
            initialState.didOfferTorFailurePromptThisForeground = true

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.overrideTorForRun = { accountUUID, useTor in
                    overrideTorCalls.withValue { $0.append((accountUUID, useTor)) }
                }
                $0.migrationManager.setPendingBackgroundTorPrompt = { _, isPending in
                    setPendingCalls.withValue { $0.append(isPending) }
                }
                $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    stop: { stopSyncCalls.withValue { $0 += 1 } },
                    isSyncing: { true }
                )
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                    executeCalls.withValue { $0 += 1 }
                    return MigrationTransferResult.success(txId: "tx-1")
                }
            }

            store.send(.torFailurePrompt(.continueWithoutTorTapped))
            await waitForRootStore { executeCalls.withValue { $0 } == 1 }

            #expect(overrideTorCalls.withValue { $0 }.count == 1)
            #expect(overrideTorCalls.withValue { $0 }.first?.0 == accountUUID)
            #expect(overrideTorCalls.withValue { $0 }.first?.1 == false)
            #expect(setPendingCalls.withValue { $0 } == [false])
            #expect(executeCalls.withValue { $0 } == 1)
            #expect(!store.state.isTorFailurePromptPresented)
            #expect(stopSyncCalls.withValue { $0 } == 1)
            #expect(refreshMigrationSyncGateCalls.withValue { $0 } == 0)
        }
    }

    /// "Try again": dismiss, clear the latch, run exactly one attempt — but do NOT override Tor.
    @Test func tryAgainClearsLatchRunsOneAttemptAndDoesNotOverrideTor() async {
        let overrideTorCalls = LockIsolated<[(AccountUUID?, Bool)]>([])
        let setPendingCalls = LockIsolated<[Bool]>([])
        let executeCalls = LockIsolated<Int>(0)
        // Fix-wave finding (review IMPORTANT): see the twin comment on
        // `continueWithoutTorClearsLatchOverridesTorOffAndRunsOneAttempt` above — both buttons share
        // the SAME attempt executor, so both must stop sync before broadcasting.
        let stopSyncCalls = LockIsolated<Int>(0)
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Self.homeState()
            initialState.isTorFailurePromptPresented = true
            initialState.didOfferTorFailurePromptThisForeground = true

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.overrideTorForRun = { accountUUID, useTor in
                    overrideTorCalls.withValue { $0.append((accountUUID, useTor)) }
                }
                $0.migrationManager.setPendingBackgroundTorPrompt = { _, isPending in
                    setPendingCalls.withValue { $0.append(isPending) }
                }
                $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    stop: { stopSyncCalls.withValue { $0 += 1 } },
                    isSyncing: { true }
                )
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                    executeCalls.withValue { $0 += 1 }
                    return MigrationTransferResult.success(txId: "tx-1")
                }
            }

            store.send(.torFailurePrompt(.tryAgainTapped))
            await waitForRootStore { executeCalls.withValue { $0 } == 1 }

            #expect(overrideTorCalls.withValue { $0 }.isEmpty)
            #expect(setPendingCalls.withValue { $0 } == [false])
            #expect(executeCalls.withValue { $0 } == 1)
            #expect(!store.state.isTorFailurePromptPresented)
            #expect(stopSyncCalls.withValue { $0 } == 1)
            #expect(refreshMigrationSyncGateCalls.withValue { $0 } == 0)
        }
    }

    /// A retry that itself fails on a Tor-class route re-arms the latch AND re-presents the sheet
    /// immediately (bypassing the once-per-foreground gate). Would regress if the re-present line
    /// (`send(.torFailurePromptPresentationChanged(true))`) were dropped.
    @Test func torClassRetryFailureRearmsLatchAndRePresents() async {
        let setPendingCalls = LockIsolated<[Bool]>([])
        // Fix-wave finding (review IMPORTANT): the attempt must stop sync before broadcasting, and a
        // failed (non-landed) broadcast must nudge the gate feed so a stop that's never followed by
        // success still resumes sync — mirrors `MigrationSendingStore.executeNextTransfer`'s catch.
        let stopSyncCalls = LockIsolated<Int>(0)
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Self.homeState()
            initialState.isTorFailurePromptPresented = true
            initialState.didOfferTorFailurePromptThisForeground = true

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.setPendingBackgroundTorPrompt = { _, isPending in
                    setPendingCalls.withValue { $0.append(isPending) }
                }
                $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.torHold }
                $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    stop: { stopSyncCalls.withValue { $0 += 1 } },
                    isSyncing: { true }
                )
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                    throw ZcashError.migrationTorUnavailable
                }
            }

            store.send(.torFailurePrompt(.tryAgainTapped))
            // Wait for the re-arm (definitive Tor-class evidence: the clear-then-re-arm pair).
            await waitForRootStore { setPendingCalls.withValue { $0.contains(true) } }
            // Then the re-present flips it back on.
            await waitForRootStore { store.state.isTorFailurePromptPresented }
            // And the gate nudge fires — a Tor-class failure never landed a broadcast, so the sync
            // stopped above for this attempt must be resumed independently of the SDK's own gate
            // (which only ever transitions on a successful broadcast).
            await waitForRootStore { refreshMigrationSyncGateCalls.withValue { $0 } == 1 }

            #expect(setPendingCalls.withValue { $0 } == [false, true])
            #expect(store.state.isTorFailurePromptPresented)
            #expect(stopSyncCalls.withValue { $0 } == 1)
            #expect(refreshMigrationSyncGateCalls.withValue { $0 } == 1)
        }
    }

    /// A retry that fails on a NON-Tor route (any error other than `.migrationTorUnavailable`/
    /// `.migrationRecordFailedAfterBroadcast`, e.g. an unreachable endpoint) must still resume sync
    /// stopped for the attempt — but, unlike the Tor-class path above, must NOT re-arm the
    /// background latch or re-present the sheet (that behavior is Tor-class-only; the route's own
    /// embedded rotation/failure UI is all a non-Tor failure gets).
    @Test func nonTorClassRetryFailureNudgesSyncGateWithoutRePresentingOrRearming() async {
        struct SomeOtherFailure: Error { }
        let setPendingCalls = LockIsolated<[Bool]>([])
        let stopSyncCalls = LockIsolated<Int>(0)
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Self.homeState()
            initialState.isTorFailurePromptPresented = true
            initialState.didOfferTorFailurePromptThisForeground = true

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.setPendingBackgroundTorPrompt = { _, isPending in
                    setPendingCalls.withValue { $0.append(isPending) }
                }
                $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.plainRetry }
                $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    stop: { stopSyncCalls.withValue { $0 += 1 } },
                    isSyncing: { true }
                )
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                    throw SomeOtherFailure()
                }
            }

            store.send(.torFailurePrompt(.tryAgainTapped))
            await waitForRootStore { refreshMigrationSyncGateCalls.withValue { $0 } == 1 }

            #expect(setPendingCalls.withValue { $0 } == [false])
            #expect(!store.state.isTorFailurePromptPresented)
            #expect(stopSyncCalls.withValue { $0 } == 1)
            #expect(refreshMigrationSyncGateCalls.withValue { $0 } == 1)
        }
    }
}

// MARK: - Shared dependency baseline (mirrors RootMigrationBackgroundTests.swift)

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
    values.migrationManager.isIronwoodActivated = { true }
    values.migrationManager.reentryRoute = { .entry }
    values.migrationManager.migrationMode = { nil }
    values.migrationManager.setMigrationMode = { _ in }
    values.migrationManager.setManualDelivery = { _ in }
    values.migrationManager.setNetworkPrivacyOptions = { _ in }
    values.migrationManager.formNetworkSnapshot = { _ in }
    values.migrationManager.markNetworkSnapshotCommitted = { _ in }
    values.migrationManager.clearProvisionalNetworkSnapshot = { _ in }
    values.migrationManager.acknowledgeComplete = { _ in }
    values.migrationManager.reconcile = { }
    values.migrationManager.clearAbandonedNetworkSnapshot = { _ in }
    values.migrationManager.recordSyncCompleted = { }
    values.migrationManager.migrationNetworkOptions = { _ in
        MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
    }
    values.migrationManager.activeNetworkSnapshots = { [] }
    values.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.plainRetry }
    values.migrationManager.setPendingBackgroundTorPrompt = { _, _ in }
    values.readTransactionsStorage.resetZashi = { }
    values.sdkSynchronizer = .noOp
    values.userMetadataProvider.load = { _ in }
    values.userNotifications.authorizationStatus = { .notDetermined }
    values.userNotifications.requestAuthorization = { false }
    values.userNotifications.scheduleMigrationNotification = { _, _, _ in }
    values.userNotifications.cancelMigrationNotifications = { }
    values.userNotifications.clearDeliveredMigrationNotifications = { }
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
    #expect(condition(), "Timed out waiting for Tor-failure-prompt Root store state", sourceLocation: sourceLocation)
}
