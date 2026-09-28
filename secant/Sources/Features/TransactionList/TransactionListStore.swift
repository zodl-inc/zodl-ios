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
        case loadingFinished
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
 
            // MOB-2020: `.transactionsUpdated` used to also clear `isInvalidated` -- but it fires on
            // EVERY write to the shared `$transactions`, including the one `accountSwitchedEffect`
            // (`RootCoordinator.swift`) makes to CLEAR the array for the account just left. That
            // clearing write was ending the loading state before the newly-selected account's own
            // fetch had answered, so Home rendered "Nothing here" for however long the fetch took.
            // `isInvalidated` is now cleared only by `.loadingFinished`, which Root sends once the
            // selected account's fetch has actually answered (`RootTransactions.swift`).
            case .transactionsUpdated:
                state.transactionListHomePage = IdentifiedArrayOf(uniqueElements: state.transactions.prefix(Constants.homePageTransactionsCount))
                state.latestTransactionId = state.transactionListHomePage.last?.id ?? ""
                return .none

            case .loadingFinished:
                state.isInvalidated = false
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
