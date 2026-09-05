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
        var CancelMigrationSnapshotId = UUID()
        var autoShieldingThreshold: Zatoshi = .zero
        /// The account the published balance was read for — see `hasConcreteBalance`.
        var concreteBalanceAccountId: AccountUUID?
        @Shared(.inMemory(.exchangeRate)) var currencyConversion: CurrencyConversion? = nil
        var fiatCurrencyResult: FiatCurrencyResult?
        var isAvailableBalanceTappable = true
        var isExchangeRateFeatureOn = false
        var isExchangeRateRefreshEnabled = false
        var isExchangeRateStale = false
        /// The SDK is withholding the spendable value until it confirms a fresh chain tip. Not a
        /// balance: it says the number is not knowable yet, which a zero balance never can.
        var isSpendableMasked = false
        /// A sync is running, so a balance may still be on its way.
        var isSyncInProgress = false
        var migratingDatabase = false
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var shieldedBalance: Zatoshi
        var shieldedWithPendingBalance: Zatoshi
        var spendability: Spendability = .everything
        var totalBalance: Zatoshi
        var transparentBalance: Zatoshi
        var awaitingResolutionBalance: Zatoshi = .zero
        var ironwoodPoolBalance: Zatoshi = .zero
        var orchardPoolBalance: Zatoshi = .zero
        var saplingPoolBalance: Zatoshi = .zero

        var isExchangeRateUSDInFlight: Bool {
            fiatCurrencyResult?.state == .fetching
        }

        /// Whether a real balance for the CURRENTLY selected account has already been published.
        /// Recorded against the account rather than as a bare flag: nothing tells this reducer
        /// when the selection changes, so a flag would go on vouching for the previous account.
        var hasConcreteBalance: Bool {
            guard let concreteBalanceAccountId else { return false }

            return concreteBalanceAccountId == selectedWalletAccount?.id
        }

        /// The spendable value is still being worked out — the only situation that deserves an
        /// "updating" affordance. Deliberately not derived from the balance: a zero spendable
        /// value is a settled answer for an empty wallet and for funds waiting on confirmations
        /// alike, and reading it as unfinished left the indicator up forever and the Send screen
        /// gated on value that was simply not spendable yet. Only two things are genuinely
        /// unfinished — the SDK withholding the value, and a sync that has published nothing yet.
        var isProcessingZeroAvailableBalance: Bool {
            isSpendableMasked || (isSyncInProgress && !hasConcreteBalance)
        }

        // Display-only: deliberately not folded into `transparentBalance`, which feeds the
        // auto-shielding threshold comparison and spendability.
        var transparentPoolBalance: Zatoshi {
            transparentBalance + awaitingResolutionBalance
        }

        var currencyValue: String {
            fiatValue(totalBalance)
        }

        var isFiatAvailable: Bool {
            isExchangeRateFeatureOn && currencyConversion != nil
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

        func fiatValue(_ balance: Zatoshi) -> String {
            currencyConversion?.convert(balance) ?? ""
        }
    }

    enum Action: Equatable {
        case availableBalanceTapped
        case balanceTapped
        case balanceUpdated(AccountBalance)
        case exchangeRateRefreshTapped
        case exchangeRateEvent(ExchangeRateClient.EchangeRateEvent)
        case onAppear
        case onDisappear
        case synchronizerStateChanged(RedactableSynchronizerState)
        case updateBalances
    }

    @Dependency(\.exchangeRate) var exchangeRate
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.userStoredPreferences) var userStoredPreferences
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    init() { }

    /// The one `spendability` derivation, shared by every place that can move one of its inputs —
    /// a fresh balance in `.balanceUpdated`, or the mask/sync flags mirrored in
    /// `.synchronizerStateChanged` — so the two can never compute a different answer for the same
    /// state.
    private func spendability(for state: State) -> Spendability {
        let everythingCondition = state.shieldedBalance.amount > 0 && ((state.shieldedBalance == state.totalBalance)
        || (!ShieldingProcessorClient.isShieldable(balance: state.transparentBalance, threshold: zcashSDKEnvironment.shieldingThreshold())
            && state.shieldedBalance == state.totalBalance - state.transparentBalance))
        || state.totalBalance == .zero

        if state.isProcessingZeroAvailableBalance {
            return .nothing
        } else if everythingCondition {
            return .everything
        } else {
            return .something
        }
    }

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
                // M3 Part B: the migration snapshot channel is the push half of the pool-truth
                // correction — a prove stores a transaction (correction grows) or a transfer
                // wallet-mines (correction shrinks) during windows where no sync event fires, and
                // the corrected pool cards must move on that clock too. Subscribed for the account
                // selected NOW; `.balanceUpdated` always reads the CURRENT account's snapshot at
                // apply time, so a stale trigger channel can never apply stale values.
                let snapshotAccountUUID = state.selectedWalletAccount?.id
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
                    .cancellable(id: state.CancelRateId, cancelInFlight: true),
                    .publisher {
                        migrationManager.migrationSnapshotEvents(snapshotAccountUUID)
                            .map { _ in Action.updateBalances }
                            .receive(on: mainQueue)
                    }
                    .cancellable(id: state.CancelMigrationSnapshotId, cancelInFlight: true)
                )

            case .onDisappear:
                // __LD2 TESTED
                return .merge(
                    .cancel(id: state.CancelStateId),
                    .cancel(id: state.CancelRateId),
                    .cancel(id: state.CancelMigrationSnapshotId)
                )
                
            case .availableBalanceTapped:
                return .none

            case .balanceTapped:
                // No-op — the parent feature decides what tapping the balance means.
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
                // Use the unmasked local snapshot for display continuity. The SDK's visible
                // balances can be spendable-masked until the new server reports a fresh tip.
                let cachedBalance = sdkSynchronizer.latestState().localAccountsBalances[account.id]
                return .run { send in
                    if let cachedBalance {
                        await send(.balanceUpdated(cachedBalance))
                    }

                    if let localBalances = try? await sdkSynchronizer.getLocalAccountBalances(),
                       let freshBalance = localBalances[account.id] {
                        if freshBalance != cachedBalance {
                            await send(.balanceUpdated(freshBalance))
                        }
                        return
                    }

                    // Do not let a masked visible balance replace a concrete local snapshot.
                    // Use the established API only when no local value is available.
                    guard cachedBalance == nil else { return }
                    if let fallbackBalance = sdkSynchronizer.latestState().localAccountsBalances[account.id] {
                        await send(.balanceUpdated(fallbackBalance))
                    } else if let fallbackBalance = try? await sdkSynchronizer.getAccountsBalances()[account.id] {
                        await send(.balanceUpdated(fallbackBalance))
                    } else if let fallbackBalance = sdkSynchronizer.latestState().accountsBalances[account.id] {
                        await send(.balanceUpdated(fallbackBalance))
                    }
                }
                
            case .balanceUpdated(let accountBalance):
                // Every path that reaches here looked the balance up by the account selected right
                // now, so that is the account this figure answers for.
                state.concreteBalanceAccountId = state.selectedWalletAccount?.id

                // Pool-agnostic accessors: sum sapling + orchard + ironwood (and any future
                // shielded pool) instead of hand-summing individual pools.
                state.shieldedBalance = accountBalance.shieldedSpendableValue
                state.shieldedWithPendingBalance = accountBalance.shieldedTotal()
                state.transparentBalance = accountBalance.unshielded
                state.totalBalance = state.shieldedWithPendingBalance + state.transparentBalance + accountBalance.awaitingResolution
                state.saplingPoolBalance = accountBalance.saplingBalance.total()

                // Display the SDK's pool summary without interpreting migration-engine status.
                // The pinned SDK updates wallet accounting when it stores the transaction at the
                // broadcast seam; confirmation only changes the balance's pending classifications.
                state.orchardPoolBalance = accountBalance.orchardBalance.total()
                state.ironwoodPoolBalance = accountBalance.ironwoodBalance.total()
                state.awaitingResolutionBalance = accountBalance.awaitingResolution

                state.spendability = spendability(for: state)
                return .none

            case .synchronizerStateChanged(let latestState):
                let snapshot = SyncStatusSnapshot.snapshotFor(state: latestState.data.syncStatus)

                if snapshot.syncStatus != .unprepared {
                    state.migratingDatabase = false
                }

                // Recorded before either guard below. The mask is a property of the synchronizer,
                // not of any one account's balance, and the states that carry it are precisely the
                // ones with nothing to publish — so deferring it past the guards would leave the
                // screen silent exactly while it should be saying it is still working this out.
                state.isSpendableMasked = latestState.data.isSpendableMasked
                state.isSyncInProgress = latestState.data.syncStatus.isSyncing

                // Re-derived here too, unconditionally: `isProcessingZeroAvailableBalance` (and an
                // account switch invalidating `hasConcreteBalance`) can change on this action alone,
                // with no balance publish following — most visibly when the guards below return
                // because there is nothing to publish for this account, which is exactly when a
                // stored `spendability` would otherwise go on repeating a now-stale answer.
                state.spendability = spendability(for: state)

                guard let account = state.selectedWalletAccount else {
                    return .none
                }

                // An absent local entry means the synchronizer does not know the selected account
                // yet. Keep the last concrete value until a durable snapshot arrives.
                guard let accountBalance = latestState.data.localAccountsBalances[account.id] else {
                    return .none
                }
                return .send(.balanceUpdated(accountBalance))
            }
        }
    }
}
