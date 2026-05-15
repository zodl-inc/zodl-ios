//
//  SignWithKeystoneCoordFlowCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-26.
//

import ComposableArchitecture

extension SignWithKeystoneCoordFlow {
    func coordinatorReduce() -> Reduce<SignWithKeystoneCoordFlow.State, SignWithKeystoneCoordFlow.Action> {
        Reduce { state, action in
            switch action {
                
                // MARK: - Scan
                
            case .path(.element(id: _, action: .scan(.foundPCZT(let pcztWithSigs)))):
                state.path.append(.sending(state.sendConfirmationState))
                return .send(.sendConfirmation(.foundPCZT(pcztWithSigs)))

            case .path(.element(id: _, action: .scan(.cancelTapped))):
                let _ = state.path.popLast()
                return .none
                
                // MARK: - Self
                
            case .sendConfirmation(.getSignatureTapped):
                var scanState = Scan.State.initial
                scanState.checkers = [.keystonePCZTScanChecker]
                state.path.append(.scan(scanState))
                return .none

            case .sendConfirmation(.updateResult(let result)):
                switch result {
                case .failure:
                    state.path.append(.sendResultFailure(state.sendConfirmationState))
                    break
                case .pending:
                    state.path.append(.sendResultPending(state.sendConfirmationState))
                    break
                case .success:
                    if state.sendConfirmationState.isShielding {
                        walletStorage.resetShieldingReminder(WalletAccount.Vendor.keystone.name())
                    }
                    state.path.append(.sendResultSuccess(state.sendConfirmationState))
                default: break
                }
                return .none
                
            case .path(.element(id: _, action: .sendResultSuccess(.viewTransactionTapped))),
                    .path(.element(id: _, action: .sendResultFailure(.viewTransactionTapped))),
                    .path(.element(id: _, action: .sendResultPending(.viewTransactionTapped))):
                if let txid = state.sendConfirmationState.txIdToExpand {
                    var transactionDetailsState = TransactionDetails.State.initial
                    if let index = state.transactions.index(id: txid) {
                        transactionDetailsState.transaction = state.transactions[index]
                    } else {
                        transactionDetailsState.transaction = TransactionState(
                            pendingSendId: txid,
                            zecAmount: state.sendConfirmationState.amount
                        )
                    }
                    transactionDetailsState.isCloseButtonRequired = true
                    state.path.append(.transactionDetails(transactionDetailsState))
                }
                return .none
                
            case .sendConfirmation(.pcztSendFailed(let error)):
                if state.path.ids.isEmpty {
                    state.path.append(.preSendingFailure(state.sendConfirmationState))
                    return .none
                }
                for element in state.path.reversed() {
                    if element.is(\.sending) {
                        return .send(.sendConfirmation(.sendFailed(error?.toZcashError(), true)))
                    } else if element.is(\.scan) {
                        state.path.append(.preSendingFailure(state.sendConfirmationState))
                        break
                    }
                }
                return .none
                
            default: return .none
            }
        }
    }
}
