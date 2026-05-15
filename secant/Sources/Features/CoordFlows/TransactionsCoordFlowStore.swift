//
//  TransactionsCoordFlowStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-20.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct TransactionsCoordFlow {
    @Reducer
    enum Path {
        case addressBookContact(AddressBook)
        case transactionDetails(TransactionDetails)
    }
    
    @ObservableState
    struct State {
        var path = StackState<Path.State>()
        var transactionDetailsState = TransactionDetails.State.initial
        @Shared(.inMemory(.transactions)) var transactions: IdentifiedArrayOf<TransactionState> = []
        var transactionsManagerState = TransactionsManager.State.initial
        var transactionToOpen: String?
        
        init() { }
    }

    enum Action {
        case path(StackActionOf<Path>)
        case transactionDetails(TransactionDetails.Action)
        case transactionsManager(TransactionsManager.Action)
    }

    init() { }

    var body: some Reducer<State, Action> {
        coordinatorReduce()

        Scope(state: \.transactionDetailsState, action: \.transactionDetails) {
            TransactionDetails()
        }
        
        Scope(state: \.transactionsManagerState, action: \.transactionsManager) {
            TransactionsManager()
        }
        
        Reduce { state, action in
            switch action {
            default: return .none
            }
        }
        .forEach(\.path, action: \.path)
    }
}
