//
//  BalancesStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 04.08.2022.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct Balances {
    @ObservableState
    struct State: Equatable {
        var stateStreamCancelId = UUID()
        var shieldingProcessorCancelId = UUID()

        var autoShieldingThreshold: Zatoshi
        var changePending: Zatoshi
        /// The account the published balance was read for — see `hasConcreteBalance`.
        var concreteBalanceAccountId: AccountUUID?
        /// Bumped every time `.updateBalancesOnAppear` starts a new request, and carried on every
        /// `.updateBalance` that request produces. A response whose generation no longer matches
        /// is from a superseded request — answering for the right account is not enough on its
        /// own, since two requests for the SAME account can still resolve out of order.
        var balanceRequestGeneration = 0
        var isShielding: Bool
        /// The SDK is withholding the spendable value until it confirms a fresh chain tip. Not a
        /// balance: it says the number is not knowable yet, which a zero balance never can.
        var isSpendableMasked = false
        /// A sync is running, so a balance may still be on its way.
        var isSyncInProgress = false
        var pendingTransactions: Zatoshi
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var shieldedBalance: Zatoshi
        var shieldedWithPendingBalance: Zatoshi = .zero
        var spendability: Spendability = .everything
        var totalBalance: Zatoshi = .zero
        @Shared(.inMemory(.transactions)) var transactions: IdentifiedArrayOf<TransactionState> = []
        @Shared(.inMemory(.unminedMigrationPendingValue)) var unminedMigrationPendingValue: Zatoshi = .zero
        var transparentBalance: Zatoshi

        var feeStr: String {
            Zatoshi(100_000).decimalString()
        }
        
        var isPendingTransaction: Bool {
            transactions.isAnythingPending()
        }

        var isPendingChange: Bool {
            changePending.amount > 0
        }

        var isPendingInProcess: Bool {
            changePending.amount + pendingTransactions.amount > 0
        }

        /// M3 B2 (MOB-1466): the "Pending" row's DISPLAYED figure — the SDK's pending lanes minus
        /// the value sitting in stored-but-unmined migration transactions, clamped at zero. The
        /// balances story renders as if the not-yet-mined migration transaction never happened
        /// (R11's standard); without this the sheet claimed the whole plan as "Pending" minutes
        /// after commit, days before anything broadcast. Activity, by contrast, now presents those
        /// rows as labeled in-flight history ("Migrating…", "Splitting Balance…") — the subtrahend
        /// is published by the same canonical pass that builds that list, so the two never drift.
        var displayedPendingBalance: Zatoshi {
            Zatoshi(max(0, changePending.amount + pendingTransactions.amount - unminedMigrationPendingValue.amount))
        }

        /// Whether the "Pending" row (and the pending header copy) should show — the corrected
        /// figure's own truth, not the raw lanes': migration-only pending renders as nothing here,
        /// because the migration surfaces and the labeled Activity rows own that in-flight story.
        var isDisplayedPendingInProcess: Bool {
            displayedPendingBalance.amount > 0
        }
        
        var isShieldableBalanceAvailable: Bool {
            ShieldingProcessorClient.isShieldable(balance: transparentBalance, threshold: autoShieldingThreshold)
        }

        var isShieldingButtonDisabled: Bool {
            isShielding || !isShieldableBalanceAvailable
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

        /// The breakdown shows the last unmasked spendable amount while the SDK is still masking
        /// the value; this flag drives the row's progress indicator and the explanatory header.
        var isSpendableValueUpdating: Bool { isSpendableMasked }

        init(
            autoShieldingThreshold: Zatoshi,
            changePending: Zatoshi,
            isShielding: Bool,
            pendingTransactions: Zatoshi,
            shieldedBalance: Zatoshi = .zero,
            transparentBalance: Zatoshi = .zero
        ) {
            self.autoShieldingThreshold = autoShieldingThreshold
            self.changePending = changePending
            self.isShielding = isShielding
            self.pendingTransactions = pendingTransactions
            self.shieldedBalance = shieldedBalance
            self.transparentBalance = transparentBalance
        }
    }

    @CasePathable
    enum Action: Equatable {
        case dismissTapped
        case everythingSpendable
        case onAppear
        case onDisappear
        case sheetHeightUpdated(CGFloat)
        case shieldFundsTapped
        case shieldingProcessorStateChanged(ShieldingProcessorClient.State)
        case synchronizerStateChanged(RedactableSynchronizerState)
        case updateBalance(AccountBalance?, AccountUUID?, Int)
        case updateBalances([AccountUUID: AccountBalance])
        case updateBalancesOnAppear
    }

    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.numberFormatter) var numberFormatter
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.shieldingProcessor) var shieldingProcessor
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    init() { }

    /// The one `spendability` derivation, shared by every place that can move one of its inputs —
    /// a fresh balance in `.updateBalance`, or the mask/sync flags mirrored in
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
                return .merge(
                    .publisher {
                        sdkSynchronizer.stateStream()
                            .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                            .map { $0.redacted }
                            .map(Action.synchronizerStateChanged)
                    }
                    .cancellable(id: state.stateStreamCancelId, cancelInFlight: true),
                    .publisher {
                        shieldingProcessor.observe()
                            .map(Action.shieldingProcessorStateChanged)
                    }
                    .cancellable(id: state.shieldingProcessorCancelId, cancelInFlight: true),
                    .send(.updateBalancesOnAppear)
                )
                
            case .onDisappear:
                // __LD2 TESTED
                return .merge(
                    .cancel(id: state.stateStreamCancelId),
                    .cancel(id: state.shieldingProcessorCancelId)
                )
            
            case .shieldingProcessorStateChanged(let shieldingProcessorState):
                state.isShielding = shieldingProcessorState == .requested
                switch shieldingProcessorState {
                case .succeeded, .nothingToShield:
                    return .send(.updateBalancesOnAppear)
                case .failed, .grpc, .proposal, .requested, .unknown:
                    return .none
                }

            case .updateBalancesOnAppear:
                guard let account = state.selectedWalletAccount else {
                    return .none
                }
                state.balanceRequestGeneration += 1
                let generation = state.balanceRequestGeneration
                let accountId = account.id
                // Same read order as the home screen's balances, so the breakdown never
                // contradicts the figure the user tapped to open it. The unmasked local snapshot
                // comes first: the SDK's visible balances can be spendable-masked until the
                // server reports a fresh tip, and a mask must not be shown as a real zero.
                let cachedBalance = sdkSynchronizer.latestState().localAccountsBalances[accountId]
                return .run { send in
                    if let cachedBalance {
                        await send(.updateBalance(cachedBalance, accountId, generation))
                    }

                    if let localBalances = try? await sdkSynchronizer.getLocalAccountBalances(),
                       let freshBalance = localBalances[accountId] {
                        if freshBalance != cachedBalance {
                            await send(.updateBalance(freshBalance, accountId, generation))
                        }
                        return
                    }

                    // Do not let a masked visible balance replace a concrete local snapshot.
                    // Use the established API only when no local value is available.
                    guard cachedBalance == nil else { return }
                    if let fallbackBalance = sdkSynchronizer.latestState().localAccountsBalances[accountId] {
                        await send(.updateBalance(fallbackBalance, accountId, generation))
                    } else if let fallbackBalance = try? await sdkSynchronizer.getAccountsBalances()[accountId] {
                        await send(.updateBalance(fallbackBalance, accountId, generation))
                    } else if let fallbackBalance = sdkSynchronizer.latestState().accountsBalances[accountId] {
                        await send(.updateBalance(fallbackBalance, accountId, generation))
                    }
                }

            case .sheetHeightUpdated:
                return .none
                
            case .dismissTapped:
                return .none
                
            case .shieldFundsTapped:
                shieldingProcessor.shieldFunds()
                return .none

            case .synchronizerStateChanged(let latestState):
                // Recorded before anything is published: the states that carry a mask are exactly
                // the ones with no balance to publish, so waiting for a balance to arrive would
                // leave the sheet silent while it should be saying the value is still coming.
                state.isSpendableMasked = latestState.data.isSpendableMasked
                state.isSyncInProgress = latestState.data.syncStatus.isSyncing

                // Re-derived here too, unconditionally: `isProcessingZeroAvailableBalance` (and an
                // account switch invalidating `hasConcreteBalance`) can change on this action alone,
                // with no balance publish following — most visibly when `.updateBalances` below
                // finds no entry for this account, which is exactly when a stored `spendability`
                // would otherwise go on repeating a now-stale answer.
                state.spendability = spendability(for: state)

                return .send(.updateBalances(latestState.data.localAccountsBalances))

            case .updateBalances(let accountsBalances):
                guard let account = state.selectedWalletAccount else {
                    return .none
                }
                // An absent entry means the synchronizer does not know the selected account yet —
                // a replayed seed state is the common case. Publish nothing rather than zeros, or
                // every replay would wipe the concrete balance the sheet is showing.
                guard let accountBalance = accountsBalances[account.id] else {
                    return .none
                }
                return .send(.updateBalance(accountBalance, account.id, state.balanceRequestGeneration))

            case .updateBalance(let accountBalance, let accountId, let generation):
                // Dropped rather than applied when either no longer holds: the account it was
                // read for (or, for a nil result, was looked up for) may no longer be selected, or
                // a later `.updateBalancesOnAppear` dispatch may already have superseded the
                // request this answers for.
                guard accountId == state.selectedWalletAccount?.id, generation == state.balanceRequestGeneration else {
                    LoggerProxy.event("[Balances] dropped a balance for a previous account or request")
                    return .none
                }
                if accountBalance != nil {
                    state.concreteBalanceAccountId = accountId
                }

                // Pool-agnostic accessors: sum sapling + orchard + ironwood (and any future
                // shielded pool) instead of hand-summing individual pools.
                state.changePending = accountBalance?.shieldedChangePendingConfirmation ?? .zero
                state.pendingTransactions = accountBalance?.shieldedValuePendingSpendability ?? .zero
                state.shieldedBalance = accountBalance?.shieldedSpendableValue ?? .zero
                state.transparentBalance = accountBalance?.unshielded ?? .zero

                state.shieldedWithPendingBalance = accountBalance?.shieldedTotal() ?? .zero
                state.totalBalance = state.shieldedWithPendingBalance + state.transparentBalance + (accountBalance?.awaitingResolution ?? .zero)

                state.spendability = spendability(for: state)
                if state.spendability == .everything {
                    return .send(.everythingSpendable)
                }
                return .none
                
            case .everythingSpendable:
                return .none
            }
        }
    }
}
