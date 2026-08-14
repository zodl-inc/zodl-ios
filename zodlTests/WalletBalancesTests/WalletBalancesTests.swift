//
//  WalletBalancesTests.swift
//  zodlTests
//
//  Batch 3 — balances. Covers WalletBalances exchange-rate handling, nil-balance spendability,
//  non-nil AccountBalance aggregation (including the Ironwood shielded pool), and computed props
//  (Features/WalletBalances/WalletBalancesStore.swift).
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

    @Test func isFiatAvailableReflectsFeatureFlagAndConversion() {
        var state = WalletBalances.State()

        // Conversion already set here so this proves the flag itself gates
        // availability, rather than trivially passing because both are unset.
        state.$currencyConversion.withLock { $0 = CurrencyConversion(.usd, ratio: 30, timestamp: 0) }
        #expect(!state.isFiatAvailable)

        state.$currencyConversion.withLock { $0 = nil }
        state.isExchangeRateFeatureOn = true
        #expect(!state.isFiatAvailable)

        state.$currencyConversion.withLock { $0 = CurrencyConversion(.usd, ratio: 30, timestamp: 0) }
        #expect(state.isFiatAvailable)
    }

    @Test func fiatValueEmptyWithoutConversionAndFormattedWithIt() {
        var state = WalletBalances.State()
        state.$currencyConversion.withLock { $0 = nil }
        #expect(state.fiatValue(Zatoshi(100_000_000)).isEmpty)

        state.$currencyConversion.withLock { $0 = CurrencyConversion(.usd, ratio: 30, timestamp: 0) }
        #expect(!state.fiatValue(Zatoshi(100_000_000)).isEmpty)
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

    // Ironwood is a third shielded pool (NU6.3 / Orchard note-version V3). The reducer must
    // pick it up through the SDK's pool-agnostic `shielded*` accessors on `AccountBalance`
    // rather than a hand-summed sapling+orchard pair, or Ironwood funds would be invisible.
    @MainActor @Test func balanceUpdatedAggregatesSaplingOrchardIronwoodAndTransparent() async {
        let store = TestStore(initialState: WalletBalances.State()) {
            WalletBalances()
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

        await store.send(.balanceUpdated(balance))

        #expect(store.state.shieldedBalance == Zatoshi(600))            // 100 + 200 + 300 spendable
        #expect(store.state.shieldedWithPendingBalance == Zatoshi(810)) // 130 + 270 + 410 totals
        #expect(store.state.transparentBalance == Zatoshi(5))           // unshielded
        #expect(store.state.totalBalance == Zatoshi(816))               // 810 + 5 + 1 awaiting
    }

    // MARK: - Pool balances

    @MainActor @Test func balanceUpdatedPopulatesPerPoolBalances() async {
        let store = TestStore(initialState: WalletBalances.State()) {
            WalletBalances()
        } withDependencies: {
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
        }
        store.exhaustivity = .off

        let balance = fullPoolAccountBalance()
        await store.send(.balanceUpdated(balance))

        #expect(store.state.saplingPoolBalance == balance.saplingBalance.total())
        #expect(store.state.orchardPoolBalance == balance.orchardBalance.total())
        #expect(store.state.ironwoodPoolBalance == balance.ironwoodBalance.total())
        #expect(store.state.awaitingResolutionBalance == balance.awaitingResolution)
    }

    @MainActor @Test func transparentPoolBalanceIncludesAwaitingResolution() async {
        let store = TestStore(initialState: WalletBalances.State()) {
            WalletBalances()
        } withDependencies: {
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
        }
        store.exhaustivity = .off

        await store.send(.balanceUpdated(fullPoolAccountBalance()))

        #expect(store.state.transparentPoolBalance == store.state.transparentBalance + store.state.awaitingResolutionBalance)
    }

    // The four displayed pool values must sum to totalBalance in every sync state — that
    // identity is what lets the pool-breakdown sheet show numbers that add up to the
    // home-screen total.
    @MainActor @Test func poolBalancesSumToTotalBalance() async {
        let store = TestStore(initialState: WalletBalances.State()) {
            WalletBalances()
        } withDependencies: {
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
        }
        store.exhaustivity = .off

        await store.send(.balanceUpdated(fullPoolAccountBalance()))

        let sum = store.state.saplingPoolBalance
            + store.state.orchardPoolBalance
            + store.state.ironwoodPoolBalance
            + store.state.transparentPoolBalance
        #expect(sum == store.state.totalBalance)
    }

    @MainActor @Test func balanceUpdatedWithNilZeroesPoolBalances() async {
        let store = TestStore(initialState: WalletBalances.State()) {
            WalletBalances()
        } withDependencies: {
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
        }
        store.exhaustivity = .off

        await store.send(.balanceUpdated(fullPoolAccountBalance()))
        await store.send(.balanceUpdated(nil))

        #expect(store.state.saplingPoolBalance == .zero)
        #expect(store.state.orchardPoolBalance == .zero)
        #expect(store.state.ironwoodPoolBalance == .zero)
        #expect(store.state.awaitingResolutionBalance == .zero)
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

    private func fullPoolAccountBalance() -> AccountBalance {
        AccountBalance(
            saplingBalance: PoolBalance(spendableValue: Zatoshi(100), changePendingConfirmation: Zatoshi(10), valuePendingSpendability: Zatoshi(20)),
            orchardBalance: PoolBalance(spendableValue: Zatoshi(200), changePendingConfirmation: Zatoshi(30), valuePendingSpendability: Zatoshi(40)),
            ironwoodBalance: PoolBalance(spendableValue: Zatoshi(300), changePendingConfirmation: Zatoshi(50), valuePendingSpendability: Zatoshi(60)),
            unshielded: Zatoshi(5),
            awaitingResolution: Zatoshi(1)
        )
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
