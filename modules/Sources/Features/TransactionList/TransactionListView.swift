import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents
import Models
import ZcashLightClientKit
import AddressBook

public struct TransactionListView: View {
    let store: StoreOf<TransactionList>
    let tokenName: String
    let scrollable: Bool

    public init(store: StoreOf<TransactionList>, tokenName: String, scrollable: Bool = true) {
        self.store = store
        self.tokenName = tokenName
        self.scrollable = scrollable
    }
    
    public var body: some View {
        WithPerceptionTracking {
            if scrollable {
                List {
                    listContent()
                }
                .disabled(store.transactions.isEmpty)
                .applyScreenBackground()
                .listStyle(.plain)
                .onAppear { store.send(.onAppear) }
            } else {
                VStack(spacing: 0) {
                    listContent()
                }
                .applyScreenBackground()
                .onAppear { store.send(.onAppear) }
            }
        }
    }
    
    @ViewBuilder private func listContent() -> some View {
        if store.isInvalidated {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<5) { _ in
                    NoTransactionPlaceholder(true)
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Asset.Colors.background.color)
            .listRowSeparator(.hidden)
        } else {
            ForEach(store.transactionListHomePage) { transaction in
                WithPerceptionTracking {
                    Button {
                        store.send(.transactionTapped(transaction.id))
                    } label: {
                        TransactionRowView(
                            transaction: transaction,
                            isUnread: TransactionList.isUnread(transaction),
                            isSwap: TransactionList.isSwap(transaction),
                            divider: store.latestTransactionId != transaction.id
                        )
                        .onAppear {
                            if transaction.requiresAutoUpdate {
                                store.send(.transactionOnAppear(transaction.id))
                            }
                        }
                    }
                    .disabled(transaction.isPIRDetectedSpend)
                    .listRowInsets(EdgeInsets())
                }
            }
            .listRowBackground(Asset.Colors.background.color)
            .listRowSeparator(.hidden)
        }
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        TransactionListView(store: .initial, tokenName: "ZEC")
            .preferredColorScheme(.light)
    }
}

// MARK: Placeholders

extension TransactionList.State {
    public static var initial: Self {
        .init()
    }
}

extension StoreOf<TransactionList> {
    public static var initial: Store<TransactionList.State, TransactionList.Action> {
        Store(
            initialState: .initial
        ) {
            TransactionList()
        }
    }
}
