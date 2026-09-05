//
//  BalancesTests.swift
//  zodlTests
//
//  Batch 3 — balances. Covers Balances reducer computed flags, updateBalance(nil)/non-nil
//  spendability + sapling/orchard/transparent aggregation, shielding-processor state, and
//  shieldFunds (Features/BalanceBreakdown/BalancesStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct BalancesTests {
    @Test func pendingFlags() {
        let pending = state(changePending: Zatoshi(5), pendingTransactions: Zatoshi(7))
        #expect(pending.isPendingChange)
        #expect(pending.isPendingInProcess)

        let idle = state()
        #expect(!idle.isPendingChange)
        #expect(!idle.isPendingInProcess)
    }

    // MARK: - M3 B2 (MOB-1466): the displayed "Pending" figure excludes in-flight migration value

    /// The sheet's Pending row shows the SDK lanes minus the value sitting in stored-but-unmined
    /// migration transactions — clamped at zero, and hidden entirely when migration is all there is.
    @Test func displayedPendingExcludesUnminedMigrationValue() {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let state = state(changePending: Zatoshi(30), pendingTransactions: Zatoshi(40))
            state.$unminedMigrationPendingValue.withLock { $0 = Zatoshi(50) }

            #expect(state.displayedPendingBalance == Zatoshi(20))
            #expect(state.isDisplayedPendingInProcess)
            // The raw predicate keeps its meaning — only the DISPLAYED figure is corrected.
            #expect(state.isPendingInProcess)
        }
    }

    @Test func displayedPendingClampsAtZeroAndHidesTheRow() {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let state = state(changePending: Zatoshi(30), pendingTransactions: Zatoshi(40))
            state.$unminedMigrationPendingValue.withLock { $0 = Zatoshi(100) }

            #expect(state.displayedPendingBalance == .zero)
            #expect(!state.isDisplayedPendingInProcess)
        }
    }

    @Test func displayedPendingEqualsRawLanesWithoutMigrationValue() {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let state = state(changePending: Zatoshi(30), pendingTransactions: Zatoshi(40))

            #expect(state.displayedPendingBalance == Zatoshi(70))
            #expect(state.isDisplayedPendingInProcess)
        }
    }

    @Test func shieldabilityFlags() {
        let shieldable = state(transparentBalance: Zatoshi(2_000_000))
        #expect(shieldable.isShieldableBalanceAvailable)
        #expect(!shieldable.isShieldingButtonDisabled)

        let belowThreshold = state(transparentBalance: Zatoshi(500))
        #expect(!belowThreshold.isShieldableBalanceAvailable)
        #expect(belowThreshold.isShieldingButtonDisabled)

        let shielding = state(isShielding: true, transparentBalance: Zatoshi(2_000_000))
        #expect(shielding.isShieldingButtonDisabled) // disabled while shielding even if available
    }

    /// "Processing with zero available" means the spendable value is still being worked out, and
    /// no shape of the balance says that. A zero spendable balance is a settled answer — nothing
    /// to spend right now — whether the rest of the wallet is confirming or transparent.
    @Test func isProcessingZeroAvailableBalance() {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var confirming = state(shieldedBalance: .zero, transparentBalance: Zatoshi(10))
            confirming.autoShieldingThreshold = Zatoshi(50)
            confirming.totalBalance = Zatoshi(10)
            #expect(!confirming.isProcessingZeroAvailableBalance)

            var hasTransparentAboveThreshold = state(shieldedBalance: .zero, transparentBalance: Zatoshi(100))
            hasTransparentAboveThreshold.autoShieldingThreshold = Zatoshi(50)
            #expect(!hasTransparentAboveThreshold.isProcessingZeroAvailableBalance)

            // The SDK declining to state the spendable value is the case that IS unresolved.
            var masked = confirming
            masked.isSpendableMasked = true
            #expect(masked.isProcessingZeroAvailableBalance)

            // So is a running sync that has not published a balance for this account yet.
            var syncingBeforeFirstBalance = state()
            syncingBeforeFirstBalance.isSyncInProgress = true
            #expect(!syncingBeforeFirstBalance.hasConcreteBalance)
            #expect(syncingBeforeFirstBalance.isProcessingZeroAvailableBalance)
        }
    }

    @Test func isPendingTransactionReflectsSharedTransactions() {
        var state = state()
        state.$transactions.withLock { $0 = [] }
        #expect(!state.isPendingTransaction)
        state.$transactions.withLock { $0 = [TransactionState(pendingSendId: "p", zecAmount: Zatoshi(1))] }
        #expect(state.isPendingTransaction)
    }

    @MainActor @Test func updateBalanceWithNilZerosAndEmitsEverythingSpendable() async {
        let store = TestStore(initialState: state(autoShieldingThreshold: Zatoshi(1_000_000))) {
            Balances()
        } withDependencies: {
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
        }
        store.exhaustivity = .off
        await store.send(.updateBalance(nil))
        await store.receive(\.everythingSpendable)
        #expect(store.state.shieldedBalance == .zero)
        #expect(store.state.totalBalance == .zero)
        #expect(store.state.spendability == .everything)
    }

    @MainActor @Test func updateBalanceAggregatesSaplingOrchardAndTransparent() async {
        let store = TestStore(initialState: state(autoShieldingThreshold: Zatoshi(1_000_000))) {
            Balances()
        } withDependencies: {
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
        }
        store.exhaustivity = .off

        let balance = AccountBalance(
            saplingBalance: PoolBalance(spendableValue: Zatoshi(100), changePendingConfirmation: Zatoshi(10), valuePendingSpendability: Zatoshi(20)),
            orchardBalance: PoolBalance(spendableValue: Zatoshi(200), changePendingConfirmation: Zatoshi(30), valuePendingSpendability: Zatoshi(40)),
            unshielded: Zatoshi(5),
            awaitingResolution: Zatoshi(1)
        )

        await store.send(.updateBalance(balance))

        #expect(store.state.changePending == Zatoshi(40))             // 10 + 30
        #expect(store.state.pendingTransactions == Zatoshi(60))       // 20 + 40
        #expect(store.state.shieldedBalance == Zatoshi(300))          // 100 + 200
        #expect(store.state.transparentBalance == Zatoshi(5))         // unshielded
        #expect(store.state.shieldedWithPendingBalance == Zatoshi(400)) // 130 + 270 totals
        #expect(store.state.totalBalance == Zatoshi(406))            // 400 + 5 + 1 awaiting
        #expect(store.state.spendability == .something)
    }

    // Ironwood is a third shielded pool (NU6.3 / Orchard note-version V3). The reducer must
    // pick it up through the SDK's pool-agnostic `shielded*` accessors on `AccountBalance`
    // rather than a hand-summed sapling+orchard pair, or Ironwood funds would be invisible.
    @MainActor @Test func updateBalanceAggregatesSaplingOrchardIronwoodAndTransparent() async {
        let store = TestStore(initialState: state(autoShieldingThreshold: Zatoshi(1_000_000))) {
            Balances()
        } withDependencies: {
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
        }
        store.exhaustivity = .off

        let balance = AccountBalance(
            saplingBalance: PoolBalance(spendableValue: Zatoshi(100), changePendingConfirmation: Zatoshi(10), valuePendingSpendability: Zatoshi(20)),
            orchardBalance: PoolBalance(spendableValue: Zatoshi(200), changePendingConfirmation: Zatoshi(30), valuePendingSpendability: Zatoshi(40)),
            ironwoodBalance: PoolBalance(spendableValue: Zatoshi(300), changePendingConfirmation: Zatoshi(50), valuePendingSpendability: Zatoshi(60)),
            unshielded: Zatoshi(5),
            awaitingResolution: Zatoshi(1)
        )

        await store.send(.updateBalance(balance))

        #expect(store.state.changePending == Zatoshi(90))              // 10 + 30 + 50
        #expect(store.state.pendingTransactions == Zatoshi(120))       // 20 + 40 + 60
        #expect(store.state.shieldedBalance == Zatoshi(600))           // 100 + 200 + 300
        #expect(store.state.transparentBalance == Zatoshi(5))          // unshielded
        #expect(store.state.shieldedWithPendingBalance == Zatoshi(810)) // 130 + 270 + 410 totals
        #expect(store.state.totalBalance == Zatoshi(816))              // 810 + 5 + 1 awaiting
        #expect(store.state.spendability == .something)
    }

    @MainActor @Test func shieldingProcessorRequestedMarksShielding() async {
        let store = TestStore(initialState: state()) { Balances() }

        await store.send(.shieldingProcessorStateChanged(.requested)) {
            $0.isShielding = true
        }
    }

    @MainActor @Test func shieldingProcessorSucceededClearsShieldingAndRefreshes() async {
        let store = TestStore(initialState: state(isShielding: true)) { Balances() }
        store.exhaustivity = .off

        await store.send(.shieldingProcessorStateChanged(.succeeded)) {
            $0.isShielding = false
        }
        // No selected account, so the refresh request is a no-op effect.
        await store.receive(\.updateBalancesOnAppear)
    }

    @MainActor @Test func shieldingProcessorNothingToShieldClearsShieldingAndRefreshes() async {
        let store = TestStore(initialState: state(isShielding: true)) { Balances() }
        store.exhaustivity = .off

        await store.send(.shieldingProcessorStateChanged(.nothingToShield)) {
            $0.isShielding = false
        }
        // No selected account, so the refresh request is a no-op effect.
        await store.receive(\.updateBalancesOnAppear)
    }

    @MainActor @Test func shieldFundsTappedInvokesProcessor() async {
        let shieldCalled = LockIsolated(false)
        let store = TestStore(initialState: state()) {
            Balances()
        } withDependencies: {
            $0.shieldingProcessor.shieldFunds = { shieldCalled.setValue(true) }
        }

        await store.send(.shieldFundsTapped)

        #expect(shieldCalled.value)
    }

    // MARK: - The breakdown reads the same unmasked local balances as the home screen

    /// A replayed `.zero` synchronizer state carries no entry for the selected account. The
    /// breakdown must publish nothing from it — anything else would replace the concrete
    /// balance on screen with zeros the moment the stream replays its seed value.
    @MainActor @Test func replayedZeroSynchronizerStatePublishesNoBalance() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = state(shieldedBalance: Zatoshi(600), transparentBalance: Zatoshi(5))
            initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            initialState.totalBalance = Zatoshi(816)
            let store = TestStore(initialState: initialState) {
                Balances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            }

            await store.send(.synchronizerStateChanged(SynchronizerState.zero.redacted)) {
                // `spendability` is re-derived on every `.synchronizerStateChanged`, from the
                // concrete balance already on screen — unrelated to, and not proof against, the
                // "no `.updateBalance` follows" assertion below.
                $0.spendability = .something
            }
            // The relay hop still runs; what must NOT follow is an `.updateBalance`. The store is
            // exhaustive here, so one would be reported as an unhandled action.
            await store.receive(\.updateBalances)
            await store.finish()

            #expect(store.state.shieldedBalance == Zatoshi(600))
            #expect(store.state.totalBalance == Zatoshi(816))
        }
    }

    /// The state stream carries both a possibly masked visible balance and the unmasked local
    /// snapshot. The breakdown must read the local one, so it agrees with the home screen
    /// instead of showing zeros while the engine withholds the spendable value.
    @MainActor @Test func synchronizerStateUsesUnmaskedLocalBalance() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let localBalance = fullPoolAccountBalance()
            let maskedBalance = AccountBalance(
                saplingBalance: .zero,
                orchardBalance: .zero,
                ironwoodBalance: .zero,
                unshielded: .zero,
                awaitingResolution: .zero
            )
            var snapshot = SynchronizerState.zero
            snapshot.accountsBalances = [testWalletAccount.id: maskedBalance]
            snapshot.localAccountsBalances = [testWalletAccount.id: localBalance]

            var initialState = state()
            initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            let store = TestStore(initialState: initialState) {
                Balances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            }
            store.exhaustivity = .off

            await store.send(.synchronizerStateChanged(snapshot.redacted))
            await store.receive(\.updateBalances)
            await store.receive(\.updateBalance)

            #expect(store.state.shieldedBalance == localBalance.shieldedSpendableValue)
            #expect(store.state.shieldedBalance != .zero)
        }
    }

    /// The instant read on appear prefers the unmasked local balances too, so opening the sheet
    /// during a server switch does not momentarily show a masked zero.
    @MainActor @Test func updateBalancesOnAppearPrefersLocalAccountBalances() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let localBalance = fullPoolAccountBalance()
            let maskedBalance = AccountBalance(
                saplingBalance: .zero,
                orchardBalance: .zero,
                ironwoodBalance: .zero,
                unshielded: .zero,
                awaitingResolution: .zero
            )
            let accountUUID = testWalletAccount.id
            var initialState = state()
            initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            let store = TestStore(initialState: initialState) {
                Balances()
            } withDependencies: {
                $0.sdkSynchronizer = .mocked(
                    getAccountsBalances: { [accountUUID: maskedBalance] },
                    getLocalAccountBalances: { [accountUUID: localBalance] }
                )
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            }
            store.exhaustivity = .off

            await store.send(.updateBalancesOnAppear)
            await store.receive(\.updateBalance)

            #expect(store.state.shieldedBalance == localBalance.shieldedSpendableValue)
        }
    }

    // MARK: - Funds pending confirmation are something to spend later, not nothing at all

    /// A self-shield waiting for confirmations: the shielded total exceeds the spendable value and
    /// there is no transparent balance left. That is a complete answer — nothing spendable right
    /// now, something spendable soon — so the breakdown must not report it as unresolved.
    @MainActor @Test func fundsPendingConfirmationAreSomethingRatherThanNothing() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = state()
            initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            let store = TestStore(initialState: initialState) {
                Balances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            }
            store.exhaustivity = .off

            await store.send(.updateBalance(pendingSelfShieldBalance()))

            #expect(store.state.shieldedBalance == .zero)
            #expect(store.state.transparentBalance == .zero)
            #expect(store.state.shieldedWithPendingBalance == Zatoshi(500))
            #expect(!store.state.isProcessingZeroAvailableBalance)
            #expect(store.state.spendability == .something)
        }
    }

    /// The same wallet while the SDK withholds the spendable value: now it IS unresolved, and the
    /// sheet must say so rather than presenting the withheld zero as a real figure.
    @MainActor @Test func aMaskedSpendableValueIsReportedAsStillBeingDetermined() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var masked = SynchronizerState.zero
            masked.isSpendableMasked = true
            masked.localAccountsBalances = [testWalletAccount.id: pendingSelfShieldBalance()]

            var initialState = state()
            initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            let store = TestStore(initialState: initialState) {
                Balances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            }
            store.exhaustivity = .off

            await store.send(.synchronizerStateChanged(masked.redacted))
            await store.receive(\.updateBalances)
            await store.receive(\.updateBalance)

            #expect(store.state.isSpendableMasked)
            #expect(store.state.isProcessingZeroAvailableBalance)
            #expect(store.state.spendability == .nothing)
        }
    }

    // MARK: - `spendability` must not go on repeating a stale answer once the flags it depends on move

    /// A masked state with no local entry for the account never reaches `.updateBalance`, where
    /// `spendability` is otherwise recomputed. Without a re-derivation here the stored answer is
    /// simply whatever it was before the mask arrived — `.everything` for a sheet that has not
    /// published a balance yet — which is exactly wrong while the SDK is still working it out.
    @MainActor @Test func aMaskWithNoLocalSnapshotLeavesSpendabilityAsStillBeingDetermined() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = state()
            initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            let store = TestStore(initialState: initialState) {
                Balances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            }
            store.exhaustivity = .off

            var masked = SynchronizerState.zero
            masked.isSpendableMasked = true
            await store.send(.synchronizerStateChanged(masked.redacted))

            #expect(store.state.isProcessingZeroAvailableBalance)
            #expect(store.state.spendability == .nothing)
        }
    }

    /// The published balance vouches for the account it was read for. Switching account while a
    /// sync is running, before anything is published for the new account, must stop `spendability`
    /// from going on answering for the account that is no longer selected.
    @MainActor @Test func spendabilityStopsAnsweringForThePreviousAccountAfterASwitch() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var syncing = SynchronizerState.zero
            syncing.syncStatus = .syncing(0.5, false)

            var initialState = state()
            initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            let store = TestStore(initialState: initialState) {
                Balances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            }
            store.exhaustivity = .off

            await store.send(.synchronizerStateChanged(syncing.redacted))
            await store.send(.updateBalance(pendingSelfShieldBalance()))
            #expect(store.state.hasConcreteBalance)
            #expect(store.state.spendability == .something)

            store.state.$selectedWalletAccount.withLock { $0 = otherWalletAccount }
            #expect(!store.state.hasConcreteBalance)
            #expect(store.state.isProcessingZeroAvailableBalance)

            // No balance has been published for the new account yet, but the next state-stream
            // tick must still stop `spendability` from going on answering for the OLD one.
            await store.send(.synchronizerStateChanged(syncing.redacted))
            #expect(store.state.isProcessingZeroAvailableBalance)
            #expect(store.state.spendability == .nothing)
        }
    }

    private var testWalletAccount: WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 9, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private var otherWalletAccount: WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 10, count: 16)),
                name: "Keystone",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private func pendingSelfShieldBalance() -> AccountBalance {
        AccountBalance(
            saplingBalance: .zero,
            orchardBalance: PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: Zatoshi(500)),
            ironwoodBalance: .zero,
            unshielded: .zero,
            awaitingResolution: .zero
        )
    }

    private func fullPoolAccountBalance() -> AccountBalance {
        AccountBalance(
            saplingBalance: PoolBalance(spendableValue: Zatoshi(100), changePendingConfirmation: Zatoshi(10), valuePendingSpendability: Zatoshi(20)),
            orchardBalance: PoolBalance(spendableValue: Zatoshi(200), changePendingConfirmation: Zatoshi(30), valuePendingSpendability: Zatoshi(40)),
            ironwoodBalance: PoolBalance(spendableValue: Zatoshi(300), changePendingConfirmation: Zatoshi(50), valuePendingSpendability: Zatoshi(60)),
            unshielded: Zatoshi(5),
            awaitingResolution: Zatoshi(1)
        )
    }

    private func state(
        autoShieldingThreshold: Zatoshi = Zatoshi(1_000_000),
        changePending: Zatoshi = .zero,
        isShielding: Bool = false,
        pendingTransactions: Zatoshi = .zero,
        shieldedBalance: Zatoshi = .zero,
        transparentBalance: Zatoshi = .zero
    ) -> Balances.State {
        Balances.State(
            autoShieldingThreshold: autoShieldingThreshold,
            changePending: changePending,
            isShielding: isShielding,
            pendingTransactions: pendingTransactions,
            shieldedBalance: shieldedBalance,
            transparentBalance: transparentBalance
        )
    }
}
