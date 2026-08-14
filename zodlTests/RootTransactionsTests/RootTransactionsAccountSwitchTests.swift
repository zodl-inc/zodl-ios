//
//  RootTransactionsAccountSwitchTests.swift
//  zodlTests
//
//  Switching between the ZODL software account and a Keystone hardware-wallet account left the
//  TRANSACTION HISTORY showing the previous account (balance switched correctly). Root cause:
//  `.fetchTransactionsForTheSelectedAccount`'s `.run` effect (`RootTransactions.swift`) reads the
//  account at DISPATCH time with no cancel id, and `.fetchedTransactions` writes the shared
//  `state.transactions` with no provenance check -- an in-flight fetch for the OLD account can
//  complete AFTER a switch and overwrite the correct list (last-writer-wins). Separately, the
//  Keystone-connect auto-select (`AddHWWalletStore`'s `.loadedWalletAccounts`) wrote
//  `selectedWalletAccount` directly with no refetch/balance reaction at all, and the manual
//  switcher only invalidated Home's mini transaction list, not the "See All" screen's.
//
//  Mirrors `FlexaTests/FlexaSecurityTests.swift`'s established pattern for Root-level tests: a
//  plain `Store` (not `TestStore`) driven with `LockIsolated` spies -- Root's init effects are too
//  heavy for exhaustive `TestStore` assertion. Keeps its own `baseNoOpDependencies` no-op
//  dependency baseline, file-scoped rather than shared, the same way that file keeps its own
//  private helpers local to itself.
//
//  NOTHING here waits on the clock. An earlier version of this file polled shared state behind
//  wall-clock budgets (3-5s), which made it load-sensitive: measured on a contended box, the whole
//  suite went from 1.4s to 23.1s and `earlierFetchDispatchSurvivesALaterDispatchAndLandsItsOwnResult`
//  alone from 0.099s to 7.384s -- a 75x stretch that walks right up to a 5s budget, and past it on
//  a busier machine. The stretch is not specific to the waits: `staleFetchFromPreviousAccountIsDroppedAfterSwitch`,
//  which awaits nothing at all, still went 0.079s -> 2.236s, because TCA runs every `.run` effect
//  body on the MAIN ACTOR (`Core.swift`'s `Task(name:priority:) { @MainActor ... }`), so every
//  effect in every parallel suite queues behind the same actor. Widening the budgets would only
//  move the cliff, so the waits are gone instead:
//
//   - "a fetch has entered the mock" is an `AsyncStream` the mocked `getAllTransactions` yields to;
//   - "this dispatch is completely finished" is `StoreTask.finish()`, which awaits the whole effect
//     tree including effects of actions the effect itself sent (`Core.swift` appends those nested
//     tasks to the same list the returned task awaits);
//   - "call #1 may now return" is an `AsyncStream` the test yields to, not a polled flag.
//
//  A machine 100x slower runs these to the same verdict, just later. `.timeLimit` is the only clock
//  left, and it exists purely so a genuinely never-resolving condition fails instead of hanging
//  forever -- it is an outer bound, never a thing correct runs close to.
//
//  `.serialized`: constructing/driving `Root.State` touches the process-global
//  `@Shared(.inMemory(.selectedWalletAccount))` / `.inMemory(.transactions)` / `.inMemory(.walletAccounts)`
//  keys, same precedent as `FlexaTests/FlexaSecurityTests.swift`, which serializes for the same
//  reason (it also drives a Root store touching this process-global state).
//
//  The only live Keystone-connect completion signal is
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

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct RootTransactionsAccountSwitchTests {
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
    /// while B is already selected, simulating the effect a real in-flight fetch would have
    /// produced once it finally completed.
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
        let (fetchEntered, fetchEnteredContinuation) = AsyncStream<AccountUUID>.makeStream()

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
                    fetchEnteredContinuation.yield(accountUUID)
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

        var entered = fetchEntered.makeAsyncIterator()

        let aFetch = store.send(.fetchTransactionsForTheSelectedAccount)
        #expect(await entered.next() == accountA.id)

        store.send(.home(.walletAccountTapped(accountB)))
        // Ends A's effect tree one way or the other and needs no budget: cancelled, it unwinds at
        // once; NOT cancelled, it runs the mocked 1s sleep out and reports `aFetchCompleted`. Both
        // outcomes are reached by waiting, so the verdict below is the same on any machine.
        await aFetch.finish()

        #expect(aFetchCancelled.value)
        #expect(!aFetchCompleted.value)
        #expect(callsStarted.value.contains(accountA.id))
    }

    // MARK: - A later fetch dispatch during a sync must not starve an earlier one

    /// Two traps an earlier draft of this test fell into -- both worth naming so they don't come
    /// back:
    ///
    /// 1. A FINITE burst of dispatches is not a valid regression guard. Whichever dispatch is
    ///    LAST has nothing after it to cancel it, so it always survives to completion under both
    ///    the shared-id `cancelInFlight: true` bug and the fix -- asserting only that "a" result
    ///    landed passes either way and proves nothing. The assertion has to be about a SPECIFIC
    ///    earlier dispatch's own result landing, never about any result landing.
    /// 2. A wall-clock window is not safe either. An earlier draft mocked `getAllTransactions` to
    ///    sleep, kept re-dispatching faster than that sleep from a background loop, and asserted
    ///    the result showed up within a fixed time budget. Swift Testing runs suites in parallel,
    ///    and under the load of the full suite that budget can blow even with the fix in place --
    ///    the test needs to tell "never" apart from "eventually", not "fast" apart from "slow".
    ///
    /// This version replaces both the burst and the clock with explicit gates:
    ///  - the mocked `getAllTransactions` hands out a distinct call index per invocation (a
    ///    `LockIsolated<Int>` counter) and returns a transaction identified by that index alone
    ///    (`"fetch-1"`, `"fetch-2"`, ...), announcing each start on an `AsyncStream`;
    ///  - call #1 PARKS on a second `AsyncStream` until the test releases it, then rethrows any
    ///    cancellation via `Task.checkCancellation()` -- load-bearing, because if the shared-id bug
    ///    cancels this effect the instant dispatch B registers, that cancellation has to leave this
    ///    closure as a thrown error so the result is dropped rather than silently returned;
    ///  - call #2 (and any later call) returns immediately.
    ///
    /// The sequence: dispatch A, await call #1's start, dispatch B -- the exact moment the shared-id
    /// bug would cancel A -- await call #2's start, await B's dispatch to FINISH (so B's `"fetch-2"`
    /// is already written and A's write is unambiguously the later one), and only THEN release call
    /// #1 and await A's own dispatch to finish. Under the fix, A survives B untouched and lands
    /// `"fetch-1"` over what B wrote. Under the bug, A was cancelled the instant B was dispatched,
    /// so `"fetch-1"` can never land -- `"fetch-2"` stays, which is exactly why the assertion names
    /// the id instead of accepting any result.
    ///
    /// Every step above is a signal, not a duration -- no budget to blow. `StoreTask.finish()`
    /// covers the whole effect tree, including the `.fetchedTransactions` each fetch sends back
    /// into the store, so "A finished" really does mean "A's write has landed".
    @Test func earlierFetchDispatchSurvivesALaterDispatchAndLandsItsOwnResult() async {
        let account = Self.walletAccount(idByte: 69)

        let callIndex = LockIsolated<Int>(0)
        let (callStarted, callStartedContinuation) = AsyncStream<Int>.makeStream()
        let (releaseFirstCall, releaseFirstCallContinuation) = AsyncStream<Void>.makeStream()

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = [] }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { _ in
                let index = callIndex.withValue { value -> Int in
                    value += 1
                    return value
                }
                callStartedContinuation.yield(index)

                if index == 1 {
                    // Parks until the test releases this call -- no polling, no flag, no clock.
                    // Cancellation is load-bearing: if the shared-id bug cancels this effect the
                    // moment dispatch B registers, the stream ends without ever yielding and
                    // `checkCancellation` rethrows it, so this call drops its result instead of
                    // returning one. Swallowing it (a `try?`) would hide the very bug under test.
                    for await _ in releaseFirstCall { break }
                    try Task.checkCancellation()
                }

                let transaction = TransactionState(
                    fee: Zatoshi(10),
                    id: "fetch-\(index)",
                    status: .received,
                    zecAmount: Zatoshi(100_000)
                )
                return IdentifiedArrayOf<TransactionState>(uniqueElements: [transaction])
            }
        }

        var started = callStarted.makeAsyncIterator()

        let earlierDispatch = store.send(.fetchTransactionsForTheSelectedAccount)
        #expect(await started.next() == 1)

        // The exact moment the shared-id/`cancelInFlight` bug would cancel call #1.
        let laterDispatch = store.send(.fetchTransactionsForTheSelectedAccount)
        #expect(await started.next() == 2)
        // B is completely done -- `"fetch-2"` is in `state.transactions` -- BEFORE call #1 is
        // released, so A's write is unambiguously the last one. (The old wall-clock version left
        // the two writes free to race: B landing after A would have overwritten `"fetch-1"` and
        // failed the assertion for a reason that had nothing to do with the bug under test.)
        await laterDispatch.finish()
        #expect(store.state.transactions.contains { $0.id == "fetch-2" })

        releaseFirstCallContinuation.yield(())
        releaseFirstCallContinuation.finish()
        await earlierDispatch.finish()

        #expect(store.state.transactions.contains { $0.id == "fetch-1" })
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

        await waitForRootState(store) { $0.transactions.contains { $0.id == "keystone-tx" } }
        // `getAccountsBalances` is ALSO called independently by SmartBanner's own priority
        // evaluation (`SmartBannerStore.swift:551`), so `balanceRequests > 0` alone can't prove
        // `.home(.walletBalances(.updateBalances))` specifically fired -- wait for its OWN
        // observable effect (the balance actually landing in `walletBalancesState`) too.
        await waitForRootState(store) { $0.homeState.walletBalancesState.shieldedBalance == keystoneBalance.shieldedSpendableValue }

        #expect(requestedAccounts.value.contains(keystoneAccount.id))
        #expect(!requestedAccounts.value.contains(zashiAccount.id))
        #expect(balanceRequests.value > 0)
        #expect(store.state.homeState.walletBalancesState.shieldedBalance == keystoneBalance.shieldedSpendableValue)
        #expect(store.state.homeState.transactionListState.isInvalidated)
        #expect(store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated)
    }

    // MARK: - Keystone-connect auto-select must reload user metadata before decorating transactions

    /// `.fetchedTransactions` (`RootTransactions.swift`) decorates the fetched list from
    /// `userMetadataProvider.allSwaps()`, not from the SDK -- a transaction whose `zAddress` matches
    /// a swap's `depositAddress` gets its `type`/`swapStatus` rewritten, and every swap-to-ZEC gets a
    /// synthetic row appended. `UserMetadataStorage` holds ONE in-memory state, for whichever account
    /// was loaded last, so without a metadata reload the freshly imported Keystone account's
    /// transactions get decorated with the PREVIOUS (ZODL) account's swap metadata. Proven by making
    /// `allSwaps()` answer with a ZODL swap until the `load` spy fires, then `[]` after -- if the
    /// fetched Keystone transaction lands still decorated with that stale swap, metadata was never
    /// reloaded before the fetch's decoration step ran.
    @Test func keystoneAutoSelectReloadsUserMetadataBeforeDecoratingTheFetchedList() async {
        let zashiAccount = Self.walletAccount(idByte: 76)
        let keystoneAccount = Self.walletAccount(idByte: 77, keystone: true)
        let loadCalled = LockIsolated<Bool>(false)

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

        // The stale ZODL account's swap -- a swap FROM zec whose deposit address matches the
        // Keystone transaction fetched below, so the decoration would visibly apply if `allSwaps()`
        // were still answering for the previous account instead of the freshly selected one.
        let staleZAddress = "stale-zodl-swap-deposit-address"
        let staleZodlSwap = UMSwapId(
            depositAddress: staleZAddress,
            provider: "near",
            totalFees: 0,
            totalUSDFees: "0",
            lastUpdated: 0,
            fromAsset: SwapConstants.zecAssetIdOnNear,
            toAsset: "near.usdc.usdc",
            exactInput: true,
            status: SwapConstants.success,
            amountOutFormatted: "0"
        )

        let keystoneTxId = "keystone-tx-matching-stale-zodl-swap"
        let keystoneTx = TransactionState(
            zAddress: staleZAddress,
            fee: Zatoshi(10),
            id: keystoneTxId,
            status: .received,
            zecAmount: Zatoshi(100_000)
        )

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { _ in
                IdentifiedArrayOf(uniqueElements: [keystoneTx])
            }
            // Flips the moment `.loadUserMetadata` reloads for the newly selected account --
            // mirrors `UserMetadataStorage` holding a single in-memory state that `load` replaces.
            $0.userMetadataProvider.load = { _ in loadCalled.setValue(true) }
            $0.userMetadataProvider.allSwaps = {
                loadCalled.value ? [] : [staleZodlSwap]
            }
        }

        store.send(
            .addKeystoneHWWalletCoordFlow(
                .path(.element(id: keystoneDeviceReadyId, action: .keystoneDeviceReady(.accountImportSucceeded)))
            )
        )

        await waitForRootState(store) { $0.transactions.contains { $0.id == keystoneTxId } }

        guard let landedTransaction = store.state.transactions[id: keystoneTxId] else {
            Issue.record("expected the Keystone transaction to have landed in state.transactions")
            return
        }

        #expect(landedTransaction.type != .swapFromZec)
        #expect(landedTransaction.type != .crossPay)
        // `TransactionState.swapStatus` isn't Optional -- its un-decorated default is `.pending`
        // (see the `tx(id:)` helper above), so "never decorated" reads as still-default here rather
        // than `nil`. The stale swap above uses `SwapConstants.success` (-> `.completed`)
        // specifically so a wrongly-applied decoration would visibly move this off `.pending`.
        #expect(landedTransaction.swapStatus == .pending)
        #expect(store.state.transactions.count == 1)
        #expect(loadCalled.value)
    }

    /// `Settings.Path.accountHWWalletSelection(.accountImportSucceeded)` is DEFENSIVE wiring, not a
    /// live UI path -- `Settings.Path` has no `.keystoneDeviceReady` case at all, and
    /// `SettingsCoordinator.swift` has no handler for `.accountHWWalletSelection(.nextTapped)`, so
    /// `AccountsSelectionView` is a dead end when reached from Settings; `.unlockTapped` (and
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

        await waitForRootState(store) { $0.transactions.contains { $0.id == "keystone-settings-tx" } }
        // See the sibling test's comment: `getAccountsBalances` is ALSO called independently by
        // SmartBanner's own priority evaluation, so wait for the update to actually land too.
        await waitForRootState(store) { $0.homeState.walletBalancesState.shieldedBalance == keystoneBalance.shieldedSpendableValue }

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

    // MARK: - (e) An unchanged fetch result must still clear the loading state

    /// `.fetchedTransactions` (`RootTransactions.swift`) only writes `state.transactions` -- and
    /// that write is the ONLY thing whose downstream `transactionsUpdated` clears `isInvalidated` on
    /// either list -- when the freshly fetched payload differs from what's already there (`if
    /// state.transactions != identifiedArray`). Switching between two accounts that BOTH have no
    /// transactions is exactly the case where the fetch's result (`[]`) equals what's already
    /// sitting in `state.transactions` (also `[]`, left over from account A): nothing gets written,
    /// so without a completion signal on that unchanged branch too, both lists are stuck showing
    /// their loading placeholder forever. This is the real Keystone-connect path: connecting a
    /// Keystone whose wallet also happens to have no transactions yet, right after
    /// `accountSwitchedEffect` has already flipped both flags to `true`.
    @Test func switchingBetweenTwoEmptyAccountsClearsTheLoadingState() async {
        let accountA = Self.walletAccount(idByte: 74)
        let accountB = Self.walletAccount(idByte: 75)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = accountA }
        initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }
        initialState.$transactions.withLock { $0 = [] }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { _ in
                []
            }
        }

        await store.send(.home(.walletAccountTapped(accountB))).finish()

        #expect(!store.state.homeState.transactionListState.isInvalidated)
        #expect(!store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated)
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

        // A same-account "switch" must dispatch no effect at all. `finish()` is the exact assertion
        // that wants making: it returns immediately when the reducer returned `.none`, and if an
        // effect WERE wrongly dispatched it waits for that effect to run to completion -- so
        // `fetchCalls` below is read after any wrongly-fired fetch has necessarily landed. The old
        // fixed 200ms sleep could only ever be too short, and a too-short sleep here passes the
        // test while proving nothing.
        await store.send(.home(.walletAccountTapped(account))).finish()

        #expect(fetchCalls.value == 0)
        #expect(store.state.transactions == existingTransactions)
        #expect(store.state.homeState.transactionListState.isInvalidated == false)
    }
}

/// Shared no-op dependency baseline for every test in this file. Kept as a private, file-scoped
/// helper rather than something shared globally, the same way `FlexaTests/FlexaSecurityTests.swift`
/// keeps its own private `waitForFlexaStore` helper local to that file.
/// Event-driven wait on store state, for the dispatches where `StoreTask.finish()` cannot be used.
///
/// The plain account switch (`.home(.walletAccountTapped)`) does settle, so those tests can and do
/// await the dispatch itself. The Keystone-connect and Settings arms cannot: on top of the same
/// switch reaction they `.merge` `.loadContacts` with a `.concatenate` of
/// `.resolveMetadataEncryptionKeys` and `.loadUserMetadata`, and that added tree never completes
/// under this file's no-op dependencies. Awaiting the whole dispatch there hangs outright -- an
/// earlier draft did exactly that and sat until the time limit -- so these tests await the state
/// they actually assert on instead.
///
/// Still no clock: `Store.publisher` emits on every state change, so this resumes on the change
/// itself, at whatever speed the machine happens to be running. The suite's `.timeLimit` is the
/// only outer bound, and only a condition that never becomes true can reach it.
@MainActor
private func waitForRootState(
    _ store: StoreOf<Root>,
    until condition: @escaping @MainActor (Root.State) -> Bool
) async {
    if condition(store.state) {
        return
    }
    for await state in store.publisher.values where condition(state) {
        return
    }
}

@MainActor
private func baseNoOpDependencies(_ values: inout DependencyValues) {
    values.databaseFiles = .noOp
    values.derivationTool = .liveValue
    values.diskSpaceChecker = .mockFullDisk
    values.flexaHandler = .noOp
    values.localAuthentication = .mockAuthenticationSucceeded
    values.mainQueue = .immediate
    values.mnemonic = .mock
    values.readTransactionsStorage.resetZashi = { }
    values.sdkSynchronizer = .noOp
    values.userMetadataProvider.load = { _ in }
    values.walletStorage = .noOp
    values.zcashSDKEnvironment = .testnet
}
