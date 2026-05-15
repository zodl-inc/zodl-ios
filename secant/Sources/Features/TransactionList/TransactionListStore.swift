import ComposableArchitecture
import SwiftUI

@Reducer
struct TransactionList {
    enum Constants {
        static let homePageTransactionsCount = 5
    }

    @ObservableState
    struct State: Equatable {
        var CancelId = UUID()

        var isInvalidated = true
        var latestTransactionId = ""
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.transactions)) var transactions: IdentifiedArrayOf<TransactionState> = []
        var transactionListHomePage: IdentifiedArrayOf<TransactionState> = []

        init() { }
    }

    enum Action: Equatable {
        case onAppear
        case transactionOnAppear(String)
        case transactionsUpdated
        case transactionTapped(String)
    }

    @Dependency(\.userMetadataProvider) var userMetadataProvider

    init() {}

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                return .publisher {
                    state.$transactions.publisher
                        .map { _ in
                            TransactionList.Action.transactionsUpdated
                        }
                }
                .cancellable(id: state.CancelId, cancelInFlight: true)
 
            case .transactionsUpdated:
                state.isInvalidated = false
                state.transactionListHomePage = IdentifiedArrayOf(uniqueElements: state.transactions.prefix(Constants.homePageTransactionsCount))
                state.latestTransactionId = state.transactionListHomePage.last?.id ?? ""
                return .none

            case .transactionTapped(let txId):
                if let index = state.transactions.index(id: txId) {
                    if TransactionList.isUnread(state.transactions[index]) {
                        userMetadataProvider.readTx(txId)
                        if let account = state.selectedWalletAccount?.account {
                            try? userMetadataProvider.store(account)
                        }
                    }
                }
                return .none
                
            case .transactionOnAppear:
                return .none
            }
        }
    }
}

extension TransactionList {
    static func isUnread(_ transaction: TransactionState) -> Bool {
        guard !transaction.isSentTransaction else {
            return false
        }

        guard !transaction.isShieldingTransaction else {
            return false
        }
        
        guard transaction.memoCount > 0 else {
            return false
        }

        @Dependency(\.userMetadataProvider) var userMetadataProvider

        return !userMetadataProvider.isRead(transaction.id, transaction.timestamp)
    }
    
    static func isSwap(_ transaction: TransactionState) -> Bool {
        @Dependency(\.userMetadataProvider) var userMetadataProvider

        return userMetadataProvider.isSwapTransaction(transaction.zAddress ?? "")
    }
}
