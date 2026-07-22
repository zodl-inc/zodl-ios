//
//  RootTransactionsMigrationBannerTests.swift
//  zodlTests
//
//  MOB-1513 (Defect A): `RootTransactions.swift`'s `.fetchedTransactions` re-entered the SmartBanner
//  evaluate cascade at `.evaluatePriority6` -- one step downstream of `.evaluatePriorityMigration` in
//  the walk (`SmartBannerStore.swift:446-565`) -- so a restored transaction history landing while the
//  banner slot was empty let currency-conversion (priority8) claim the slot ahead of a pending
//  Ironwood migration banner (rank 1.5, meant to outrank everything below priority2).
//
//  This is the one test in the MOB-1513 set that can genuinely fail before the fix and pass after
//  it: the defect is entirely in WHICH action `RootTransactions.swift:118` sends, not in
//  `SmartBannerStore.swift` itself -- both `.evaluatePriority6` and `.evaluatePriorityMigration`
//  already behave correctly in isolation (see `SmartBannerMigrationTests.swift`), so a
//  `SmartBanner`-only `TestStore` cannot observe the wiring bug -- only a `Root`-level test that
//  actually runs `Root.transactionsReduce()`'s effect and lets it flow into the `Home`/`SmartBanner`
//  scope can. Mirrors `RootMigrationRoutingTests.swift`'s `Store` + `waitForRootStore` polling
//  pattern (Root's init effects are too heavy for exhaustive `TestStore` assertion — see that file's
//  header doc) rather than `TestStore`, and keeps its own private copies of the two helpers, same
//  precedent as `RootMigrationRoutingTests.swift`/`RootMigrationBackgroundTests.swift`/
//  `RootTorFailurePromptTests.swift`.
//
//  `.serialized`: constructing/driving `Root.State` touches the process-global
//  `@Shared(.inMemory(.selectedWalletAccount))` / `.inMemory(.transactions)` / `.inMemory(.walletStatus)`
//  keys, same precedent as `SmartBannerMigrationTests`/`RootMigrationRoutingTests`.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RootTransactionsMigrationBannerTests {
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

    /// MOB-1513 (Defect A): reproduces the exact post-restore scenario -- empty banner slot, a
    /// funded account (a nonzero shielded balance, so `.evaluatePriority8`'s own zero-balance skip
    /// doesn't short-circuit it), a passed backup test (so `.evaluatePriority6` falls through instead
    /// of claiming the slot itself), no exchange rate configured (`.evaluatePriority8`'s own trigger
    /// condition), and a pending Ironwood migration (`bannerVariant` stubbed `.required`). Sending
    /// `.fetchedTransactions` with a changed transaction list is the exact effect
    /// `.observeTransactions`'s event-stream/state-stream publishers produce once a restore's history
    /// lands (`RootTransactions.swift:17-44`) -- this drives whatever re-entry action production code
    /// actually sends at line 118, so a fix scoped to that one call site (and only there) is what
    /// flips this test from red to green.
    ///
    /// Pre-fix (`.evaluatePriority6`): falls through priority6/7/75 exactly as stubbed below and
    /// claims the slot at priority8 (currency conversion) -- migration is never even consulted.
    /// Post-fix (`.evaluatePriorityMigration`): migration is consulted FIRST and claims the slot
    /// before priority8 is ever reached.
    @Test func restoredTransactionHistoryPrefersMigrationOverCurrencyConversion() async {
        let account = Self.walletAccount(idByte: 42)

        var mutableBackedUpWallet = StoredWallet.placeholder
        mutableBackedUpWallet.hasUserPassedPhraseBackupTest = true
        let backedUpWallet = mutableBackedUpWallet

        let fundedBalance = AccountBalance(
            saplingBalance: PoolBalance.zero,
            orchardBalance: PoolBalance(
                spendableValue: Zatoshi(100_000),
                changePendingConfirmation: .zero,
                valuePendingSpendability: .zero
            ),
            unshielded: .zero
        )
        var mutableFundedState = SynchronizerState.zero
        mutableFundedState.accountsBalances = [account.id: fundedBalance]
        let fundedState = mutableFundedState

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = [] }
        initialState.$walletStatus.withLock { $0 = .none }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.migrationManager.bannerVariant = { accountUUID in
                #expect(accountUUID == account.id)
                return MigrationBannerVariant.required
            }
            $0.userStoredPreferences.exchangeRate = { nil }
            $0.userMetadataProvider.allSwaps = { [] }
            $0.walletStorage.exportWallet = { backedUpWallet }
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(latestState: { fundedState })
        }

        let transaction = TransactionState(fee: nil, id: "restored-tx-1", status: .received, zecAmount: Zatoshi(100_000))
        store.send(.fetchedTransactions(IdentifiedArrayOf(uniqueElements: [transaction])))

        await waitForRootStore { store.state.homeState.smartBannerState.priorityContent != nil }

        #expect(store.state.homeState.smartBannerState.priorityContent == SmartBanner.State.PriorityContent.priorityMigration)
        #expect(store.state.homeState.smartBannerState.priorityContent != SmartBanner.State.PriorityContent.priority8)
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
