//
//  TransactionsCoordFlowCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-20.
//

import ComposableArchitecture

extension TransactionsCoordFlow {
    func coordinatorReduce() -> Reduce<TransactionsCoordFlow.State, TransactionsCoordFlow.Action> {
        Reduce { state, action in
            switch action {

                // MARK: - Address Book Contact

            case .path(.element(id: _, action: .addressBookContact(.dismissAddContactRequired))):
                let _ = state.path.popLast()
                return .none
                
                // MARK: - Self: Transaction Details

            case .transactionDetails(.saveAddressTapped):
                var addressBookState = AddressBook.State.initial
                addressBookState.address = state.transactionDetailsState.transaction.address
                addressBookState.isValidZcashAddress = true
                addressBookState.isNameFocused = true
                addressBookState.context = .send
                state.path.append(.addressBookContact(addressBookState))
                return .none
                
                // MARK: - Self: Transaction Manager
                
            case .transactionsManager(.transactionTapped(let txId)):
                if let index = state.transactions.index(id: txId) {
                    var transactionDetailsState = TransactionDetails.State.initial
                    transactionDetailsState.transaction = state.transactions[index]
                    state.path.append(.transactionDetails(transactionDetailsState))
                }
                return .none
                
                // MARK: - Transaction Details
                
            case .path(.element(id: _, action: .transactionDetails(.saveAddressTapped))):
                for element in state.path {
                    if case .transactionDetails(let transactionDetailsState) = element {
                        var addressBookState = AddressBook.State.initial
                        addressBookState.address = transactionDetailsState.transaction.address
                        addressBookState.isValidZcashAddress = true
                        addressBookState.isNameFocused = true
                        addressBookState.context = .send
                        state.path.append(.addressBookContact(addressBookState))
                    }
                }
                return .none
                
            case .path(.element(id: _, action: .transactionDetails(.closeDetailTapped))):
                let _ = state.path.removeLast()
                return .none

            default: return .none
            }
        }
    }
}
