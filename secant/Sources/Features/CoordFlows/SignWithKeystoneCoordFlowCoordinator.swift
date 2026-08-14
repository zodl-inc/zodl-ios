//
//  SignWithKeystoneCoordFlowCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-26.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

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

            // No `.confirmWithKeystone` element to pop back to — this coordinator's root screen
            // already is it — so mirror `.keystoneFirmwareUpdateCloseTapped` below and clear the
            // internal path directly.
            case .sendConfirmation(.cancelTapped):
                state.path.removeAll()
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

            // MOB-1510: root-level `.sendConfirmation` action, not `.path(...)`-wrapped — this
            // coordinator has no `.confirmWithKeystone` path element; the root screen already is it.
            // Clearing first drops the stale `.scan`/`.sending` pushed before the gate ran.
            case .sendConfirmation(.keystoneFirmwareUpdateRequired):
                state.path.removeAll()
                state.path.append(.keystoneFirmwareUpdate(state.sendConfirmationState))
                return .none

            // No `.confirmWithKeystone` element to pop back to — clear the path and reset the root
            // state directly so a fresh scan isn't dropped by the `isKeystoneCodeFound` guard.
            case .path(.element(id: _, action: .keystoneFirmwareUpdate(.keystoneFirmwareUpdateCloseTapped))):
                state.path.removeAll()
                state.sendConfirmationState.detectedKeystoneFirmware = nil
                state.sendConfirmationState.isKeystoneCodeFound = false
                keystoneHandler.resetQRDecoder()
                return .none

            default: return .none
            }
        }
    }
}
