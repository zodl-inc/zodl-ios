//
//  WalletBalancesMaskedSpendableTests.swift
//  zodlTests
//
//  Covers the SDK's "the spendable value is masked" signal as it reaches the app: the mirror on
//  RedactableSynchronizerState, the WalletBalances state flag, and the Send form's gates
//  (Utils/SensitiveData.swift, Features/WalletBalances/WalletBalancesStore.swift,
//  Features/SendForm/SendFormStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct WalletBalancesMaskedSpendableTests {
    private var testWalletAccount: WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 7, count: 16)),
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
                id: AccountUUID(id: [UInt8](repeating: 8, count: 16)),
                name: "Keystone",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    // MARK: - The redacted wrapper carries the signal at all

    @Test func redactableSynchronizerStateMirrorsIsSpendableMasked() {
        var masked = SynchronizerState.zero
        masked.isSpendableMasked = true
        #expect(masked.redacted.data.isSpendableMasked)

        #expect(!SynchronizerState.zero.redacted.data.isSpendableMasked)
    }

    // MARK: - WalletBalances mirrors it, even with nothing to publish

    @MainActor @Test func synchronizerStateChangedMirrorsMaskWithoutALocalSnapshot() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = WalletBalances.State()
            state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            let store = TestStore(initialState: state) {
                WalletBalances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            }
            store.exhaustivity = .off

            // `.zero` has no entry for the selected account, so nothing is published from it —
            // the mask must still be recorded, or the screen would never say it is working.
            var masked = SynchronizerState.zero
            masked.isSpendableMasked = true
            await store.send(.synchronizerStateChanged(masked.redacted))
            #expect(store.state.isSpendableMasked)

            await store.send(.synchronizerStateChanged(SynchronizerState.zero.redacted))
            #expect(!store.state.isSpendableMasked)
        }
    }

    // MARK: - `spendability` must not go on repeating a stale answer once the flags it depends on move

    /// A masked state with no local entry for the account never reaches `.balanceUpdated`, where
    /// `spendability` is otherwise recomputed. Without a re-derivation here the stored answer is
    /// simply whatever it was before the mask arrived — `.everything` for a wallet that has not
    /// published a balance yet — which hides the "still updating" row exactly when it should show.
    @MainActor @Test func aMaskWithNoLocalSnapshotLeavesSpendabilityAsStillBeingDetermined() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = WalletBalances.State()
            state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            let store = TestStore(initialState: state) {
                WalletBalances()
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

    @MainActor @Test func synchronizerStateChangedMirrorsMaskAlongsideAPublishedBalance() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var masked = SynchronizerState.zero
            masked.isSpendableMasked = true
            masked.localAccountsBalances = [testWalletAccount.id: fullPoolAccountBalance()]

            var state = WalletBalances.State()
            state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            let store = TestStore(initialState: state) {
                WalletBalances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            }
            store.exhaustivity = .off

            await store.send(.synchronizerStateChanged(masked.redacted))
            await store.receive(\.balanceUpdated)

            #expect(store.state.isSpendableMasked)
            #expect(store.state.shieldedBalance == fullPoolAccountBalance().shieldedSpendableValue)
        }
    }

    // MARK: - The Send form waits for the value instead of calling it insufficient

    @Test func sendFormHoldsTheFormWhileTheSpendableValueIsMasked() {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SendForm.State.initial
            let previousAccount = state.selectedWalletAccount
            state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

            state.isValidAddress = true
            // `SendForm.State.amount` is hard-wired to zero under the test build, so the only way
            // to drive `amount > shieldedBalance` true here is a spendable balance below zero.
            // The production case this stands for is the opposite shape and the same comparison:
            // a masked spendable value reads as zero, so any typed amount exceeds it.
            state.shieldedBalance = Zatoshi(-1)
            state.walletBalancesState.isSpendableMasked = false
            #expect(state.isInsufficientFunds)

            state.walletBalancesState.isSpendableMasked = true

            #expect(state.isSpendabilityBeingDetermined)
            // Without the gate the form would tell the user the funds are insufficient for an
            // amount the wallet may well be able to send once the value stops being masked.
            #expect(!state.isInsufficientFunds)
            // A held error is not enough on its own — Send must stay disabled too, or tapping it
            // would submit an amount nothing has checked against a real spendable balance.
            #expect(!state.isValidForm)

            state.walletBalancesState.isSpendableMasked = false
            #expect(!state.isSpendabilityBeingDetermined)
            #expect(state.isInsufficientFunds)
        }
    }

    @Test func sendFormUnmaskedKeepsTheOrdinaryInsufficientFundsAnswer() {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SendForm.State.initial
            let previousAccount = state.selectedWalletAccount
            state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

            state.isValidAddress = true
            state.shieldedBalance = Zatoshi(100_000)
            state.walletBalancesState.isSpendableMasked = false

            #expect(!state.isSpendabilityBeingDetermined)
            #expect(!state.isInsufficientFunds)
            #expect(state.isValidForm)
        }
    }

    // MARK: - Funds pending confirmation are something to spend later, not nothing at all

    /// A self-shield waiting for confirmations: the shielded total exceeds the spendable value and
    /// no transparent balance is left. Nothing is spendable this minute, but that is the complete
    /// answer — the home screen must not spin over it as though the figure were still coming.
    @MainActor @Test func fundsPendingConfirmationAreSomethingRatherThanNothing() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = WalletBalances.State()
            state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            let store = TestStore(initialState: state) {
                WalletBalances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            }
            store.exhaustivity = .off

            await store.send(.balanceUpdated(pendingSelfShieldBalance(), testWalletAccount.id, 0))

            #expect(store.state.shieldedBalance == .zero)
            #expect(store.state.transparentBalance == .zero)
            #expect(store.state.shieldedWithPendingBalance == Zatoshi(500))
            #expect(!store.state.isProcessingZeroAvailableBalance)
            #expect(store.state.spendability == .something)
        }
    }

    /// A running sync that has not published anything yet genuinely has no answer, so it reads as
    /// unresolved — until the first balance for the selected account arrives.
    @MainActor @Test func aRunningSyncIsUnresolvedOnlyUntilTheFirstBalanceArrives() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var syncing = SynchronizerState.zero
            syncing.syncStatus = .syncing(0.5, false)

            var state = WalletBalances.State()
            state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            let store = TestStore(initialState: state) {
                WalletBalances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            }
            store.exhaustivity = .off

            await store.send(.synchronizerStateChanged(syncing.redacted))
            #expect(store.state.isSyncInProgress)
            #expect(!store.state.hasConcreteBalance)
            #expect(store.state.isProcessingZeroAvailableBalance)

            await store.send(.balanceUpdated(pendingSelfShieldBalance(), testWalletAccount.id, 0))
            #expect(store.state.hasConcreteBalance)
            #expect(!store.state.isProcessingZeroAvailableBalance)
        }
    }

    /// The published balance vouches for the account it was read for. Switching account must not
    /// let the previous account's figure keep answering for the new one — nothing tells this
    /// reducer that the selection changed, so the record has to carry the account with it. Nor may
    /// `spendability` — a stored snapshot, unlike `hasConcreteBalance` — keep repeating the old
    /// account's answer once the next state-stream tick has a chance to revisit it.
    @MainActor @Test func aBalanceStopsVouchingWhenTheSelectedAccountChanges() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var syncing = SynchronizerState.zero
            syncing.syncStatus = .syncing(0.5, false)

            var state = WalletBalances.State()
            state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
            let store = TestStore(initialState: state) {
                WalletBalances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            }
            store.exhaustivity = .off

            await store.send(.synchronizerStateChanged(syncing.redacted))
            await store.send(.balanceUpdated(pendingSelfShieldBalance(), testWalletAccount.id, 0))
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
}
