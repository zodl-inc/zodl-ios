//
//  TransactionsCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2023-03-20.
//

import SwiftUI
import Combine
import ComposableArchitecture

struct TransactionsCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @PlatformBindable var store: StoreOf<TransactionsCoordFlow>
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
            .zashiNavigationBarHidden(true)
        }
        // macOS: this flow hosts the Activity List, which must be full-width so its (visible) scroll
        // indicator sits at the window edge, not the 530-column edge. The content cap is moved OFF the
        // flow (`capped: false`) and onto each screen: Activity caps per-row via `.macContentRowCap()`,
        // while TransactionDetails / AddressBookContact self-cap via their own backgrounds. The flow
        // background stays full-bleed either way. iOS unaffected — `capped: false` collapses to the same
        // background-only path there (Rule #11).
        .applyScreenBackground(capped: false)
        .zashiSectionRootBack()
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
    static var initial: TransactionsCoordFlow.State { TransactionsCoordFlow.State() }
}

extension TransactionsCoordFlow {
    @MainActor static let placeholder = StoreOf<TransactionsCoordFlow>(
        initialState: .initial
    ) {
        TransactionsCoordFlow()
    }
}
