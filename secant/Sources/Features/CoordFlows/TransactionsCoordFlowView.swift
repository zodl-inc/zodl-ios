//
//  TransactionsCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2023-03-20.
//

import SwiftUI
import ComposableArchitecture

struct TransactionsCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<TransactionsCoordFlow>
    let tokenName: String

    init(store: StoreOf<TransactionsCoordFlow>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                if store.transactionToOpen != nil {
                    TransactionDetailsView(
                        store:
                            store.scope(
                                state: \.transactionDetailsState,
                                action: \.transactionDetails
                            ),
                        tokenName: tokenName
                    )
                } else {
                    TransactionsManagerView(
                        store:
                            store.scope(
                                state: \.transactionsManagerState,
                                action: \.transactionsManager
                            ),
                        tokenName: tokenName
                    )
                }
            } destination: { store in
                switch store.case {
                case let .addressBookContact(store):
                    AddressBookContactView(store: store)
                case let .transactionDetails(store):
                    TransactionDetailsView(store: store, tokenName: tokenName)
                }
            }
            .navigationBarHidden(true)
        }
        .applyScreenBackground()
        .zashiBack()
        .screenTitle(String(localizable: .generalRequest))
    }
}

#Preview {
    NavigationView {
        TransactionsCoordFlowView(store: TransactionsCoordFlow.placeholder, tokenName: "ZEC")
    }
}

// MARK: - Placeholders

extension TransactionsCoordFlow.State {
    static let initial = TransactionsCoordFlow.State()
}

extension TransactionsCoordFlow {
    static let placeholder = StoreOf<TransactionsCoordFlow>(
        initialState: .initial
    ) {
        TransactionsCoordFlow()
    }
}
