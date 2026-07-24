//
//  RootTransactionsAccountSwitchTests.swift
//  zodlTests
//
//  MOB-1513 (T-B): switching between the ZODL software account and a Keystone hardware-wallet
//  account left the TRANSACTION HISTORY showing the previous account (balance switched correctly).
//  Root cause: `.fetchTransactionsForTheSelectedAccount`'s `.run` effect
//  (`RootTransactions.swift`) reads the account at DISPATCH time with no cancel id, and
//  `.fetchedTransactions` writes the shared `state.transactions` with no provenance check -- an
//  in-flight fetch for the OLD account can complete AFTER a switch and overwrite the correct list
//  (last-writer-wins). Separately, the Keystone-connect auto-select (`AddHWWalletStore`'s
//  `.loadedWalletAccounts`) wrote `selectedWalletAccount` directly with no refetch/balance reaction
//  at all, and the manual switcher only invalidated Home's mini transaction list, not the "See All"
//  screen's.
//
//  Mirrors `RootTransactionsMigrationBannerTests.swift`/`RootMigrationRoutingTests.swift`/
//  `FlexaTests/FlexaSecurityTests.swift`'s established pattern for Root-level tests: a plain `Store`
//  (not `TestStore`) driven with `LockIsolated` spies and polling -- Root's init effects are too
//  heavy for exhaustive `TestStore` assertion. Keeps its own private copies of the two shared
//  helpers, same precedent as those files.
//
//  `.serialized`: constructing/driving `Root.State` touches the process-global
//  `@Shared(.inMemory(.selectedWalletAccount))` / `.inMemory(.transactions)` / `.inMemory(.walletAccounts)`
//  keys, same precedent as the sibling Root-level test files.
//
//  MOB-1513 (Fix wave 1 correction): the ONLY live Keystone-connect completion signal is
//  `.addKeystoneHWWalletCoordFlow(.path(.element(id: _, action: .keystoneDeviceReady(.accountImportSucceeded))))`
//  -- see `keystoneAutoSelectImmediatelyRefreshesTransactionsAndBalance` below. Both
//  `.accountHWWalletSelection(.accountImportSucceeded)` arms (`AddKeystoneHWWalletCoordFlow`'s own
//  and `Settings`'s) are defensive/dead wiring, not reachable UI paths -- see
//  `settingsAccountHWWalletSelectionAppliesSwitchReactionsAsDefensiveWiring`'s doc comment for why.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RootTransactionsAccountSwitchTests {
    private static func walletAccount(idByte: UInt8, keystone: Bool = false) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: keystone ? "Keystone" : "Zodl",
                keySource: keystone ? String(localizable: .accountsKeystone).lowercased() : nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private func tx(id: String) -> TransactionState {
        TransactionState(fee: Zatoshi(10), id: id, status: .received, zecAmount: Zatoshi(100_000))
    }

    /// A distinctive, nonzero balance used by the Keystone-parity tests below to prove
    /// `.home(.walletBalances(.updateBalances))` specifically fired -- `getAccountsBalances` is
    /// ALSO called independently by SmartBanner's own priority evaluation
    /// (`SmartBannerStore.swift:551`), so a raw call-count spy alone can't tell the two apart; only
    /// `walletBalancesState` actually landing this value proves the real round trip happened.
    private static let keystoneBalance = AccountBalance(
        saplingBalance: .zero,
        orchardBalance: PoolBalance(spendableValue: Zatoshi(555_000), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
        unshielded: .zero
    )

    // MARK: - (a) Provenance guard: a stale fetch for the OLD account must never overwrite

    /// The exact race from the bug report: a fetch dispatched for account A is still in flight when
    /// the user switches to account B; A's payload finally arrives AFTER the switch. It must be
    /// dropped, never applied -- proven by directly injecting the late `.fetchedTransactions` action
    /// while B is already selected, mirroring how the sibling `RootTransactionsMigrationBannerTests`
    /// injects `.fetchedTransactions` to simulate the effect a real fetch would have produced.
    @Test func staleFetchFromPreviousAccountIsDroppedAfterSwitch() async {
        let accountA = Self.walletAccount(idByte: 60)
        let accountB = Self.walletAccount(idByte: 61)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = accountB }
        let currentForB = IdentifiedArrayOf<TransactionState>(uniqueElements: [tx(id: "b-tx")])
        initialState.$transactions.withLock { $0 = currentForB }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
        }

        // A's stale payload, arriving after B is already selected.
        let staleForA = IdentifiedArrayOf<TransactionState>(uniqueElements: [tx(id: "a-tx")])
        store.send(.fetchedTransactions(accountA.id, staleForA))

        #expect(store.state.transactions == currentForB)
        #expect(store.state.selectedWalletAccount == accountB)
    }

    /// The guard must not be so broad that it drops a legitimate update for the account that IS
    /// currently selected.
    @Test func fetchedTransactionsForTheCurrentlySelectedAccountStillApplies() async {
        let account = Self.walletAccount(idByte: 65)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = [] }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
        }

        let freshTransactions = IdentifiedArrayOf<TransactionState>(uniqueElements: [tx(id: "fresh-tx")])
        store.send(.fetchedTransactions(account.id, freshTransactions))

        #expect(store.state.transactions == freshTransactions)
    }

    // MARK: - (b) Switching cancels the in-flight fetch for the previous account

    /// A slow fetch for account A must be CANCELLED the moment the user switches to B -- the fetch's
    /// own completion effect (a `send`) must never run for A once the switch happens. Proven by
    /// making the mocked `getAllTransactions` closure hang on a cancellable `Task.sleep` for A only,
    /// and observing that cancellation actually reaches it (not just that state stays correct --
    /// that's the provenance-guard test above).
    @Test func switchingAccountsCancelsInFlightFetchForThePreviousAccount() async {
        let accountA = Self.walletAccount(idByte: 62)
        let accountB = Self.walletAccount(idByte: 63)
        let callsStarted = LockIsolated<[AccountUUID]>([])
        let aFetchCompleted = LockIsolated<Bool>(false)
        let aFetchCancelled = LockIsolated<Bool>(false)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = accountA }
        initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                if let accountUUID {
                    callsStarted.withValue { $0.append(accountUUID) }
                }
                if accountUUID == accountA.id {
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        aFetchCompleted.setValue(true)
                    } catch {
                        aFetchCancelled.setValue(true)
                        throw error
                    }
                }
                return []
            }
        }

        store.send(.fetchTransactionsForTheSelectedAccount)
        await waitForRootStore(timeoutNanoseconds: 3_000_000_000) { callsStarted.value.contains(accountA.id) }

        store.send(.home(.walletAccountTapped(accountB)))
        await waitForRootStore(timeoutNanoseconds: 3_000_000_000) { aFetchCancelled.value }

        #expect(aFetchCancelled.value)
        #expect(!aFetchCompleted.value)
    }

    // MARK: - (c) Keystone-connect auto-select parity

    /// `AddHWWalletStore`'s `.loadedWalletAccounts` flips `state.selectedWalletAccount` directly
    /// (no Root-visible "switch" action of its own) immediately before sending
    /// `.accountImportSucceeded` in the same effect -- Root must react to that signal exactly like
    /// the manual switcher: refetch transactions for the NEW account and refresh its balance,
    /// without waiting for the user to dismiss the "Keystone Connected" confirmation screen.
    @Test func keystoneAutoSelectImmediatelyRefreshesTransactionsAndBalance() async {
        let zashiAccount = Self.walletAccount(idByte: 70)
        let keystoneAccount = Self.walletAccount(idByte: 71, keystone: true)
        let requestedAccounts = LockIsolated<[AccountUUID]>([])
        let balanceRequests = LockIsolated<Int>(0)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = zashiAccount }
        initialState.$walletAccounts.withLock { $0 = [zashiAccount] }
        initialState.path = Root.State.Path.addKeystoneHWWalletCoordFlow
        initialState.addKeystoneHWWalletCoordFlowState.path.append(.keystoneDeviceReady(AddKeystoneHWWallet.State()))
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        guard let keystoneDeviceReadyId = initialState.addKeystoneHWWalletCoordFlowState.path.ids.last else {
            Issue.record("expected a keystoneDeviceReady element id on the Add Keystone HW Wallet path")
            return
        }

        // Mirrors AddHWWalletStore's own `.loadedWalletAccounts`, which writes this SAME shared
        // state directly, immediately before `.accountImportSucceeded` is sent (same `.run` effect)
        // -- by the time Root observes `.accountImportSucceeded`, the switch has already happened.
        initialState.$selectedWalletAccount.withLock { $0 = keystoneAccount }
        initialState.$walletAccounts.withLock { $0 = [zashiAccount, keystoneAccount] }

        let keystoneTx = tx(id: "keystone-tx")
        // Captured as a local first -- `Self.keystoneBalance` is `@MainActor`-isolated (via the
        // enclosing suite), but `getAccountsBalances` below is `@Sendable`.
        let keystoneBalance = Self.keystoneBalance

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            // `getAccountsBalances` is a `let` on `SDKSynchronizerClient`, so it can't be mutated
            // in place like `getAllTransactions` -- replace the whole client via `.mocked(...)`.
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getAllTransactions: { accountUUID in
                    if let accountUUID {
                        requestedAccounts.withValue { $0.append(accountUUID) }
                    }
                    return IdentifiedArrayOf(uniqueElements: [keystoneTx])
                },
                getAccountsBalances: {
                    balanceRequests.withValue { $0 += 1 }
                    return [keystoneAccount.id: keystoneBalance]
                }
            )
        }

        store.send(
            .addKeystoneHWWalletCoordFlow(
                .path(.element(id: keystoneDeviceReadyId, action: .keystoneDeviceReady(.accountImportSucceeded)))
            )
        )

        await waitForRootStore { store.state.transactions.contains { $0.id == "keystone-tx" } }
        // `getAccountsBalances` is ALSO called independently by SmartBanner's own priority
        // evaluation (`SmartBannerStore.swift:551`), so `balanceRequests > 0` alone can't prove
        // `.home(.walletBalances(.updateBalances))` specifically fired -- wait for its OWN
        // observable effect (the balance actually landing in `walletBalancesState`) too.
        await waitForRootStore { store.state.homeState.walletBalancesState.shieldedBalance == keystoneBalance.shieldedSpendableValue }

        #expect(requestedAccounts.value.contains(keystoneAccount.id))
        #expect(!requestedAccounts.value.contains(zashiAccount.id))
        #expect(balanceRequests.value > 0)
        #expect(store.state.homeState.walletBalancesState.shieldedBalance == keystoneBalance.shieldedSpendableValue)
        #expect(store.state.homeState.transactionListState.isInvalidated)
        #expect(store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated)
    }

    /// MOB-1513 (Fix wave 1 correction): `Settings.Path.accountHWWalletSelection(.accountImportSucceeded)`
    /// is DEFENSIVE wiring, not a live UI path -- `Settings.Path` has no `.keystoneDeviceReady` case
    /// at all, and `SettingsCoordinator.swift` has no handler for `.accountHWWalletSelection(.nextTapped)`,
    /// so `AccountsSelectionView` is a dead end when reached from Settings; `.unlockTapped` (and
    /// therefore `.accountImported`/`.accountImportSucceeded`) is never reachable from that step.
    /// (The SAME is true of `AddKeystoneHWWalletCoordFlow`'s own `.accountHWWalletSelection(.accountImportSucceeded)`
    /// arm above it in `RootCoordinator.swift` -- its `.nextTapped` only ever pushes forward to
    /// `.keystoneDeviceReady`, never fires unlock directly from that step either.) Live coverage of
    /// the Keystone-connect parity fix is `keystoneAutoSelectImmediatelyRefreshesTransactionsAndBalance`
    /// above (`.keystoneDeviceReady(.accountImportSucceeded)`, the one actually-reachable completion
    /// signal). This test still earns its keep as a regression guard for the dead/defensive arm: if
    /// it's ever wired live (or the dead branch is deleted and this one repurposed), the switch
    /// reactions must already be correct here.
    @Test func settingsAccountHWWalletSelectionAppliesSwitchReactionsAsDefensiveWiring() async {
        let zashiAccount = Self.walletAccount(idByte: 72)
        let keystoneAccount = Self.walletAccount(idByte: 73, keystone: true)
        let requestedAccounts = LockIsolated<[AccountUUID]>([])
        let balanceRequests = LockIsolated<Int>(0)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = zashiAccount }
        initialState.$walletAccounts.withLock { $0 = [zashiAccount] }
        initialState.path = Root.State.Path.settings
        initialState.settingsState.path.append(.accountHWWalletSelection(AddKeystoneHWWallet.State()))
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        guard let elementId = initialState.settingsState.path.ids.last else {
            Issue.record("expected an accountHWWalletSelection element id on the Settings path")
            return
        }

        initialState.$selectedWalletAccount.withLock { $0 = keystoneAccount }
        initialState.$walletAccounts.withLock { $0 = [zashiAccount, keystoneAccount] }

        let keystoneTx = tx(id: "keystone-settings-tx")
        // Captured as a local first -- `Self.keystoneBalance` is `@MainActor`-isolated (via the
        // enclosing suite), but `getAccountsBalances` below is `@Sendable`.
        let keystoneBalance = Self.keystoneBalance

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            // `getAccountsBalances` is a `let` on `SDKSynchronizerClient`, so it can't be mutated
            // in place like `getAllTransactions` -- replace the whole client via `.mocked(...)`.
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getAllTransactions: { accountUUID in
                    if let accountUUID {
                        requestedAccounts.withValue { $0.append(accountUUID) }
                    }
                    return IdentifiedArrayOf(uniqueElements: [keystoneTx])
                },
                getAccountsBalances: {
                    balanceRequests.withValue { $0 += 1 }
                    return [keystoneAccount.id: keystoneBalance]
                }
            )
        }

        store.send(
            .settings(
                .path(.element(id: elementId, action: .accountHWWalletSelection(.accountImportSucceeded)))
            )
        )

        await waitForRootStore { store.state.transactions.contains { $0.id == "keystone-settings-tx" } }
        // See the sibling test's comment: `getAccountsBalances` is ALSO called independently by
        // SmartBanner's own priority evaluation, so wait for the update to actually land too.
        await waitForRootStore { store.state.homeState.walletBalancesState.shieldedBalance == keystoneBalance.shieldedSpendableValue }

        #expect(requestedAccounts.value.contains(keystoneAccount.id))
        #expect(balanceRequests.value > 0)
        #expect(store.state.homeState.walletBalancesState.shieldedBalance == keystoneBalance.shieldedSpendableValue)
        #expect(store.state.homeState.transactionListState.isInvalidated)
        #expect(store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated)
        #expect(store.state.path == nil)
    }

    // MARK: - (d) See-All invalidation mirrors Home's on every switch

    @Test func walletAccountSwitchInvalidatesBothHomeAndSeeAllTransactionLists() async {
        let accountA = Self.walletAccount(idByte: 67)
        let accountB = Self.walletAccount(idByte: 68)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = accountA }
        initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
        }

        store.send(.home(.walletAccountTapped(accountB)))

        #expect(store.state.homeState.transactionListState.isInvalidated)
        #expect(store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated)
        #expect(store.state.selectedWalletAccount == accountB)
    }

    // MARK: - No-op guard regression

    /// Re-selecting the already-selected account must remain a complete no-op -- no fetch, no
    /// invalidation, no state churn. (Pre-existing guard in `.home(.walletAccountTapped)`; this
    /// guards the refactor around it.)
    @Test func reselectingAlreadySelectedAccountRemainsANoOp() async {
        let account = Self.walletAccount(idByte: 66)
        let existingTransactions = IdentifiedArrayOf<TransactionState>(uniqueElements: [tx(id: "existing-tx")])
        let fetchCalls = LockIsolated<Int>(0)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = existingTransactions }
        initialState.homeState.transactionListState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { _ in
                fetchCalls.withValue { $0 += 1 }
                return []
            }
        }

        store.send(.home(.walletAccountTapped(account)))

        // A same-account "switch" must dispatch no effect at all -- give a wrongly-fired async
        // fetch a brief moment to land, then confirm nothing changed.
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(fetchCalls.value == 0)
        #expect(store.state.transactions == existingTransactions)
        #expect(store.state.homeState.transactionListState.isInvalidated == false)
    }
}

/// Mirrors `RootMigrationRoutingTests.swift`'s identically-named helper -- see that file's doc for
/// why each Root-level test file keeps its own private copy rather than sharing one.
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
    #expect(condition(), "Timed out waiting for Root transactions/account-switch store state", sourceLocation: sourceLocation)
}
