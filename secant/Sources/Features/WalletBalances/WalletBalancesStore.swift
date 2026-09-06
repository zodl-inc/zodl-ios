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
        /// The account the published balance was read for — see `hasConcreteBalance`.
        var concreteBalanceAccountId: AccountUUID?
        /// Bumped every time `.updateBalances` starts a new request, and carried on every
        /// `.balanceUpdated` that request produces. A response whose generation no longer matches
        /// is from a superseded request — answering for the right account is not enough on its
        /// own, since two requests for the SAME account can still resolve out of order.
        var balanceRequestGeneration = 0
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
        case balanceUpdated(AccountBalance, AccountUUID, Int)
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
                // The selection may have just changed; `hasConcreteBalance` already answers for
                // the new account, so the stored spendability must follow before any balance
                // arrives — otherwise it would go on repeating whatever the PREVIOUS account's
                // answer was for however long this request takes to resolve.
                state.spendability = spendability(for: state)
                state.balanceRequestGeneration += 1
                let generation = state.balanceRequestGeneration
                let accountId = account.id
                // Use the unmasked local snapshot for display continuity. The SDK's visible
                // balances can be spendable-masked until the new server reports a fresh tip.
                let cachedBalance = sdkSynchronizer.latestState().localAccountsBalances[accountId]
                return .run { send in
                    if let cachedBalance {
                        await send(.balanceUpdated(cachedBalance, accountId, generation))
                    }

                    if let localBalances = try? await sdkSynchronizer.getLocalAccountBalances(),
                       let freshBalance = localBalances[accountId] {
                        if freshBalance != cachedBalance {
                            await send(.balanceUpdated(freshBalance, accountId, generation))
                        }
                        return
                    }

                    // Do not let a masked visible balance replace a concrete local snapshot.
                    // Use the established API only when no local value is available.
                    guard cachedBalance == nil else { return }
                    if let fallbackBalance = sdkSynchronizer.latestState().localAccountsBalances[accountId] {
                        await send(.balanceUpdated(fallbackBalance, accountId, generation))
                    } else if let fallbackBalance = try? await sdkSynchronizer.getAccountsBalances()[accountId] {
                        await send(.balanceUpdated(fallbackBalance, accountId, generation))
                    } else if let fallbackBalance = sdkSynchronizer.latestState().accountsBalances[accountId] {
                        await send(.balanceUpdated(fallbackBalance, accountId, generation))
                    }
                }

            case .balanceUpdated(let accountBalance, let accountId, let generation):
                // Dropped rather than applied when either no longer holds: the account it was
                // read for may no longer be selected, or a later `.updateBalances` dispatch may
                // already have superseded the request this answers for.
                guard accountId == state.selectedWalletAccount?.id, generation == state.balanceRequestGeneration else {
                    LoggerProxy.event("[WalletBalances] dropped a balance for a previous account or request")
                    return .none
                }
                state.concreteBalanceAccountId = accountId

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
                return .send(.balanceUpdated(accountBalance, account.id, state.balanceRequestGeneration))
            }
        }
    }
}
