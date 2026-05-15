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
        var isShielding: Bool
        var pendingTransactions: Zatoshi
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var shieldedBalance: Zatoshi
        var shieldedWithPendingBalance: Zatoshi = .zero
        var spendability: Spendability = .everything
        var totalBalance: Zatoshi = .zero
        @Shared(.inMemory(.transactions)) var transactions: IdentifiedArrayOf<TransactionState> = []
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
        
        var isShieldableBalanceAvailable: Bool {
            transparentBalance.amount >= autoShieldingThreshold.amount
        }

        var isShieldingButtonDisabled: Bool {
            isShielding || !isShieldableBalanceAvailable
        }

        var isProcessingZeroAvailableBalance: Bool {
            if shieldedBalance.amount == 0 && transparentBalance.amount > autoShieldingThreshold.amount {
                return false
            }
            
            return totalBalance.amount != shieldedBalance.amount && shieldedBalance.amount == 0
        }

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
        case updateBalance(AccountBalance?)
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
    
    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.autoShieldingThreshold = zcashSDKEnvironment.shieldingThreshold
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
                if shieldingProcessorState == .succeeded {
                    return .send(.updateBalancesOnAppear)
                }
                return .none

            case .updateBalancesOnAppear:
                guard let account = state.selectedWalletAccount else {
                    return .none
                }
                return .run { send in
                    if let accountBalance = try? await sdkSynchronizer.getAccountsBalances()[account.id] {
                        await send(.updateBalance(accountBalance))
                    } else if let accountBalance = sdkSynchronizer.latestState().accountsBalances[account.id] {
                        await send(.updateBalance(accountBalance))
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
                return .send(.updateBalances(latestState.data.accountsBalances))

            case .updateBalances(let accountsBalances):
                guard let account = state.selectedWalletAccount else {
                    return .none
                }
                return .send(.updateBalance(accountsBalances[account.id]))

            case .updateBalance(let accountBalance):
                state.changePending = (accountBalance?.saplingBalance.changePendingConfirmation ?? .zero) +
                    (accountBalance?.orchardBalance.changePendingConfirmation ?? .zero)
                state.pendingTransactions = (accountBalance?.saplingBalance.valuePendingSpendability ?? .zero) +
                    (accountBalance?.orchardBalance.valuePendingSpendability ?? .zero)
                state.shieldedBalance = (accountBalance?.saplingBalance.spendableValue ?? .zero) + (accountBalance?.orchardBalance.spendableValue ?? .zero)
                state.transparentBalance = accountBalance?.unshielded ?? .zero

                state.shieldedWithPendingBalance = (accountBalance?.saplingBalance.total() ?? .zero) + (accountBalance?.orchardBalance.total() ?? .zero)
                state.totalBalance = state.shieldedWithPendingBalance + state.transparentBalance + (accountBalance?.awaitingResolution ?? .zero)

                let everythingCondition = state.shieldedBalance.amount > 0 && ((state.shieldedBalance == state.totalBalance)
                || (state.transparentBalance < zcashSDKEnvironment.shieldingThreshold && state.shieldedBalance == state.totalBalance - state.transparentBalance))
                || state.totalBalance == .zero
                
                // spendability
                if state.isProcessingZeroAvailableBalance {
                    state.spendability = .nothing
                } else if everythingCondition {
                    state.spendability = .everything
                    return .send(.everythingSpendable)
                } else {
                    state.spendability = .something
                }
                return .none
                
            case .everythingSpendable:
                return .none
            }
        }
    }
}

extension IdentifiedArrayOf<TransactionState> {
    func isAnythingPending() -> Bool {
        return contains(where: \.isPending)
    }
}
