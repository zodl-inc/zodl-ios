//
//  WalletBalancesTests.swift
//  zodlTests
//
//  Batch 3 — balances. Covers WalletBalances exchange-rate handling, nil-balance spendability,
//  computed props (Features/WalletBalances/WalletBalancesStore.swift), and the non-nil
//  AccountBalance aggregation path across all shielded pools (Sapling + Orchard + Ironwood).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct WalletBalancesTests {
    // MARK: - Computed props

    @Test func isProcessingZeroAvailableBalance() {
        var transparentAboveThreshold = WalletBalances.State(shieldedBalance: .zero, totalBalance: Zatoshi(100), transparentBalance: Zatoshi(100))
        transparentAboveThreshold.autoShieldingThreshold = Zatoshi(50)
        #expect(!transparentAboveThreshold.isProcessingZeroAvailableBalance)

        var shieldedZeroPending = WalletBalances.State(shieldedBalance: .zero, totalBalance: Zatoshi(10), transparentBalance: Zatoshi(10))
        shieldedZeroPending.autoShieldingThreshold = Zatoshi(50)
        #expect(shieldedZeroPending.isProcessingZeroAvailableBalance)

        let hasShielded = WalletBalances.State(shieldedBalance: Zatoshi(100), totalBalance: Zatoshi(200), transparentBalance: Zatoshi(100))
        #expect(!hasShielded.isProcessingZeroAvailableBalance)
    }

    @Test func currencyValueIsEmptyWithoutConversionAndFormattedWithIt() {
        var state = WalletBalances.State(totalBalance: Zatoshi(100_000_000))
        #expect(state.currencyValue.isEmpty)
        state.$currencyConversion.withLock { $0 = CurrencyConversion(.usd, ratio: 30, timestamp: 0) }
        #expect(!state.currencyValue.isEmpty)
    }

    // MARK: - balanceUpdated(nil)

    @MainActor @Test func balanceUpdatedWithNilZerosBalancesAndMarksEverythingSpendable() async {
        let store = TestStore(initialState: WalletBalances.State()) {
            WalletBalances()
        } withDependencies: {
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
        }
        store.exhaustivity = .off
        await store.send(.balanceUpdated(nil))
        #expect(store.state.shieldedBalance == .zero)
        #expect(store.state.totalBalance == .zero)
        #expect(store.state.spendability == .everything)
    }

    @MainActor @Test func balanceUpdatedAggregatesAllShieldedPoolsIncludingIronwood() async {
        // sapling: 1 / 2 / 4   orchard: 8 / 16 / 32   ironwood: 64 / 128 / 256
        let accountBalance = AccountBalance(
            saplingBalance: PoolBalance(spendableValue: Zatoshi(1), changePendingConfirmation: Zatoshi(2), valuePendingSpendability: Zatoshi(4)),
            orchardBalance: PoolBalance(spendableValue: Zatoshi(8), changePendingConfirmation: Zatoshi(16), valuePendingSpendability: Zatoshi(32)),
            ironwoodBalance: PoolBalance(spendableValue: Zatoshi(64), changePendingConfirmation: Zatoshi(128), valuePendingSpendability: Zatoshi(256)),
            unshielded: .zero
        )
        let store = TestStore(initialState: WalletBalances.State()) {
            WalletBalances()
        } withDependencies: {
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
        }
        store.exhaustivity = .off
        await store.send(.balanceUpdated(accountBalance))
        #expect(store.state.shieldedBalance == Zatoshi(1 + 8 + 64))
        #expect(store.state.shieldedWithPendingBalance == Zatoshi((1 + 2 + 4) + (8 + 16 + 32) + (64 + 128 + 256)))
        #expect(store.state.totalBalance == Zatoshi((1 + 2 + 4) + (8 + 16 + 32) + (64 + 128 + 256)))
    }

    // MARK: - exchangeRateEvent

    @MainActor @Test func exchangeRateValueSetsConversionAndClearsStale() async {
        let store = makeStore()
        let result = fiatResult(rate: 30)
        await store.send(.exchangeRateEvent(.value(result, .usd)))
        #expect(store.state.fiatCurrencyResult == result)
        #expect(store.state.currencyConversion?.iso4217 == .usd)
        #expect(!store.state.isExchangeRateStale)
        #expect(!store.state.isExchangeRateRefreshEnabled)
    }

    @MainActor @Test func exchangeRateRefreshEnableSetsRefreshFlag() async {
        let store = makeStore()
        await store.send(.exchangeRateEvent(.refreshEnable(fiatResult(rate: 30), .usd)))
        #expect(store.state.isExchangeRateRefreshEnabled)
        #expect(store.state.currencyConversion != nil)
    }

    @MainActor @Test func exchangeRateStaleClearsConversion() async {
        let store = makeStore(currencyConversion: CurrencyConversion(.usd, ratio: 30, timestamp: 0))
        await store.send(.exchangeRateEvent(.stale(nil, .usd)))
        #expect(store.state.currencyConversion == nil)
        #expect(store.state.isExchangeRateStale)
    }

    @MainActor @Test func exchangeRateValueNilIsNoOp() async {
        let store = makeStore(currencyConversion: CurrencyConversion(.usd, ratio: 30, timestamp: 0))
        await store.send(.exchangeRateEvent(.value(nil, .usd)))
        #expect(store.state.currencyConversion != nil)
    }

    // MARK: - Helpers

    private func fiatResult(rate: Double) -> FiatCurrencyResult {
        FiatCurrencyResult(date: Date(timeIntervalSince1970: 1000), rate: NSDecimalNumber(value: rate), state: .success)
    }

    @MainActor
    private func makeStore(currencyConversion: CurrencyConversion? = nil) -> TestStoreOf<WalletBalances> {
        var state = WalletBalances.State()
        state.$currencyConversion.withLock { $0 = currencyConversion }
        let store = TestStore(initialState: state) { WalletBalances() }
        store.exhaustivity = .off
        return store
    }
}
