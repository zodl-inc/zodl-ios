//
//  WalletBalancesStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 04-02-2024
//

import Foundation
import ComposableArchitecture

@preconcurrency import ZcashLightClientKit

@Reducer
struct WalletBalances {
    @ObservableState
    struct State: Equatable {
        var CancelStateId = UUID()
        var CancelRateId = UUID()
        var autoShieldingThreshold: Zatoshi = .zero
        @Shared(.inMemory(.exchangeRate)) var currencyConversion: CurrencyConversion? = nil
        var fiatCurrencyResult: FiatCurrencyResult?
        var isAvailableBalanceTappable = true
        var isExchangeRateFeatureOn = false
        var isExchangeRateRefreshEnabled = false
        var isExchangeRateStale = false
        var migratingDatabase = false
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var shieldedBalance: Zatoshi
        var shieldedWithPendingBalance: Zatoshi
        var spendability: Spendability = .everything
        var totalBalance: Zatoshi
        var transparentBalance: Zatoshi

        var isExchangeRateUSDInFlight: Bool {
            fiatCurrencyResult?.state == .fetching
        }
        
        var isProcessingZeroAvailableBalance: Bool {
            if shieldedBalance.amount == 0 && transparentBalance.amount > autoShieldingThreshold.amount {
                return false
            }
            
            return totalBalance.amount != shieldedBalance.amount && shieldedBalance.amount == 0
        }

        var currencyValue: String {
            currencyConversion?.convert(totalBalance) ?? ""
        }
        
        init(
            fiatCurrencyResult: FiatCurrencyResult? = nil,
            isAvailableBalanceTappable: Bool = true,
            isExchangeRateFeatureOn: Bool = false,
            isExchangeRateRefreshEnabled: Bool = false,
            isExchangeRateStale: Bool = false,
            migratingDatabase: Bool = false,
            shieldedBalance: Zatoshi = .zero,
            shieldedWithPendingBalance: Zatoshi = .zero,
            totalBalance: Zatoshi = .zero,
            transparentBalance: Zatoshi = .zero
        ) {
            self.fiatCurrencyResult = fiatCurrencyResult
            self.isAvailableBalanceTappable = isAvailableBalanceTappable
            self.isExchangeRateFeatureOn = isExchangeRateFeatureOn
            self.isExchangeRateRefreshEnabled = isExchangeRateRefreshEnabled
            self.isExchangeRateStale = isExchangeRateStale
            self.migratingDatabase = migratingDatabase
            self.shieldedBalance = shieldedBalance
            self.shieldedWithPendingBalance = shieldedWithPendingBalance
            self.totalBalance = totalBalance
            self.transparentBalance = transparentBalance
        }
    }
    
    enum Action: Equatable {
        case availableBalanceTapped
        case balanceUpdated(AccountBalance?)
        case exchangeRateRefreshTapped
        case exchangeRateEvent(ExchangeRateClient.EchangeRateEvent)
        case onAppear
        case onDisappear
        case synchronizerStateChanged(RedactableSynchronizerState)
        case updateBalances
    }

    @Dependency(\.exchangeRate) var exchangeRate
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.userStoredPreferences) var userStoredPreferences
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                 state.autoShieldingThreshold = zcashSDKEnvironment.shieldingThreshold()
                if let exchangeRate = userStoredPreferences.exchangeRate(), exchangeRate.automatic {
                    state.isExchangeRateFeatureOn = true
                } else {
                    state.isExchangeRateFeatureOn = false
                }
                return .merge(
                    .send(.updateBalances),
                    .publisher {
                        sdkSynchronizer.stateStream()
                            .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                            .map { $0.redacted }
                            .map(Action.synchronizerStateChanged)
                    }
                    .cancellable(id: state.CancelStateId, cancelInFlight: true),
                    .publisher {
                        exchangeRate.exchangeRateEventStream()
                            .map(Action.exchangeRateEvent)
                            .receive(on: mainQueue)
                    }
                    .cancellable(id: state.CancelRateId, cancelInFlight: true)
                )

            case .onDisappear:
                // __LD2 TESTED
                return .merge(
                    .cancel(id: state.CancelStateId),
                    .cancel(id: state.CancelRateId)
                )
                
            case .availableBalanceTapped:
                return .none

            case .exchangeRateRefreshTapped:
                exchangeRate.refreshExchangeRateUSD()
                return .none
                
            case .exchangeRateEvent(let result):
                switch result {
                case .value(let rate, let currency):
                    guard let rate else {
                        return .none
                    }

                    state.fiatCurrencyResult = rate
                    state.$currencyConversion.withLock {
                        $0 = CurrencyConversion(currency, ratio: rate.rate.doubleValue, timestamp: rate.date.timeIntervalSince1970)
                    }
                    state.isExchangeRateRefreshEnabled = false
                    state.isExchangeRateStale = false
                case .refreshEnable(let rate, let currency):
                    guard let rate else {
                        return .none
                    }

                    state.fiatCurrencyResult = rate
                    state.$currencyConversion.withLock {
                        $0 = CurrencyConversion(currency, ratio: rate.rate.doubleValue, timestamp: rate.date.timeIntervalSince1970)
                    }
                    state.isExchangeRateRefreshEnabled = true
                    state.isExchangeRateStale = false
                case .stale(let rate, let currency):
                    if let rate {
                        state.fiatCurrencyResult = rate
                        state.$currencyConversion.withLock {
                            $0 = CurrencyConversion(currency, ratio: rate.rate.doubleValue, timestamp: rate.date.timeIntervalSince1970)
                        }
                    } else {
                        state.fiatCurrencyResult = nil
                        state.$currencyConversion.withLock { $0 = nil }
                    }
                    state.isExchangeRateStale = true
                    state.isExchangeRateRefreshEnabled = true
                }
                
                return .none

            case .updateBalances:
                guard let account = state.selectedWalletAccount else {
                    return .none
                }
                return .run { send in
                    if let accountBalance = try? await sdkSynchronizer.getAccountsBalances()[account.id] {
                        await send(.balanceUpdated(accountBalance))
                    } else if let accountBalance = sdkSynchronizer.latestState().accountsBalances[account.id] {
                        await send(.balanceUpdated(accountBalance))
                    }
                }
                
            case .balanceUpdated(let accountBalance):
                // Pool-agnostic accessors: sum sapling + orchard + ironwood (and any future
                // shielded pool) instead of hand-summing individual pools.
                state.shieldedBalance = accountBalance?.shieldedSpendableValue ?? .zero
                state.shieldedWithPendingBalance = accountBalance?.shieldedTotal() ?? .zero
                state.transparentBalance = accountBalance?.unshielded ?? .zero
                state.totalBalance = state.shieldedWithPendingBalance + state.transparentBalance + (accountBalance?.awaitingResolution ?? .zero)
               
                let everythingCondition = state.shieldedBalance.amount > 0 && ((state.shieldedBalance == state.totalBalance)
                || (state.transparentBalance < zcashSDKEnvironment.shieldingThreshold() && state.shieldedBalance == state.totalBalance - state.transparentBalance))
                || state.totalBalance == .zero

                // spendability
                if state.isProcessingZeroAvailableBalance {
                    state.spendability = .nothing
                } else if everythingCondition {
                    state.spendability = .everything
                } else {
                    state.spendability = .something
                }
                return .none

            case .synchronizerStateChanged(let latestState):
                let snapshot = SyncStatusSnapshot.snapshotFor(state: latestState.data.syncStatus)

                if snapshot.syncStatus != .unprepared {
                    state.migratingDatabase = false
                }

                guard let account = state.selectedWalletAccount else {
                    return .none
                }

                return .send(.balanceUpdated(latestState.data.accountsBalances[account.id]))
            }
        }
    }
}
