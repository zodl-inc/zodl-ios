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
