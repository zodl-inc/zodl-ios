//
//  TransactionsManagerStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 01-22-2025.
//

import ComposableArchitecture
import SwiftUI
import ZcashLightClientKit
import Utils
import Models
import Generated
import Pasteboard
import SDKSynchronizer
import ReadTransactionsStorage
import ZcashSDKEnvironment
import AddressBookClient
import UIComponents
import AddressBook
import NumberFormatter
import UserMetadataProvider

@Reducer
public struct TransactionsManager {
    public struct Section: Equatable, Identifiable {
        public let id: String
        public var latestTransactionId = ""
        let timestamp: TimeInterval
        public let transactions: IdentifiedArrayOf<TransactionState>
    }
    
    public enum Filter: Equatable {
        case bookmarked
        case contact
        case memos
        case notes
        case received
        case sent
        case swap
        case unread
    }

    @ObservableState
    public struct State: Equatable {
        public var CancelId = UUID()

        public var activeFilters: [Filter] = []
        @Shared(.inMemory(.addressBookContacts)) public var addressBookContacts: AddressBookContacts = .empty
        public var filteredTransactionsList: IdentifiedArrayOf<TransactionState> = []
        public var filtersRequest = false
        public var isInvalidated = true
        public var searchedTransactionsList: IdentifiedArrayOf<TransactionState> = []
        public var searchTerm = ""
        public var selectedFilters: [Filter] = []
        @Shared(.inMemory(.selectedWalletAccount)) public var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.transactions)) public var transactions: IdentifiedArrayOf<TransactionState> = []
        public var transactionSections: [Section] = []
        @Shared(.inMemory(.zashiWalletAccount)) public var zashiWalletAccount: WalletAccount? = nil

        public var isBookmarkedFilterActive: Bool { selectedFilters.contains(.bookmarked) }
        public var isContactFilterActive: Bool { selectedFilters.contains(.contact) }
        public var isMemosFilterActive: Bool { selectedFilters.contains(.memos) }
        public var isNotesFilterActive: Bool { selectedFilters.contains(.notes) }
        public var isReceivedFilterActive: Bool { selectedFilters.contains(.received) }
        public var isSentFilterActive: Bool { selectedFilters.contains(.sent) }
        public var isSwapFilterActive: Bool { selectedFilters.contains(.swap) }
        public var isUnreadFilterActive: Bool { selectedFilters.contains(.unread) }

        public init() { }
    }
    
    public enum Action: BindableAction, Equatable {
        case asynchronousMemoSearchResult([String])
        case applyFiltersTapped
        case binding(BindingAction<TransactionsManager.State>)
        case dismissRequired
        case eraseSearchTermTapped
        case filterTapped
        case onAppear
        case resetFiltersTapped
        case toggleFilter(Filter)
        case transactionOnAppear(String)
        case transactionsUpdated
        case transactionTapped(String)
        case updateTransactionPeriods
        case updateTransactionsAccordingToFilters
        case updateTransactionsAccordingToSearchTerm
    }

    @Dependency(\.addressBook) var addressBook
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.numberFormatter) var numberFormatter
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.userMetadataProvider) var userMetadataProvider
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    public init() { }

    public var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                return .publisher {
                    state.$transactions.publisher
                        .map { _ in
                            TransactionsManager.Action.transactionsUpdated
                        }
                }
                .cancellable(id: state.CancelId, cancelInFlight: true)

            case .binding(\.searchTerm):
                return .send(.updateTransactionsAccordingToSearchTerm)

            case .binding:
                return .none

            case .dismissRequired:
                return .none
                
            case .applyFiltersTapped:
                state.activeFilters = state.selectedFilters
                state.filtersRequest = false
                return .send(.updateTransactionsAccordingToSearchTerm)

            case .resetFiltersTapped:
                state.selectedFilters.removeAll()
                state.activeFilters.removeAll()
                return .send(.updateTransactionsAccordingToSearchTerm)

            case .eraseSearchTermTapped:
                state.searchTerm = ""
                return .send(.updateTransactionsAccordingToSearchTerm)
                
            case .filterTapped:
                state.selectedFilters = state.activeFilters
                state.filtersRequest = true
                return .none
                
            case .toggleFilter(let filter):
                if state.selectedFilters.contains(filter) {
                    state.selectedFilters.removeAll { $0 == filter }
                } else {
                    state.selectedFilters.append(filter)
                }
                return .none

            case .transactionTapped(let txId):
                if let index = state.transactions.index(id: txId) {
                    if TransactionsManager.isUnread(state.transactions[index]) {
                        userMetadataProvider.readTx(txId)
                        if let account = state.selectedWalletAccount?.account {
                            try? userMetadataProvider.store(account)
                        }
                    }
                }
                return .none

            case .transactionsUpdated:
                state.isInvalidated = false
                return .send(.updateTransactionsAccordingToSearchTerm)

            case .updateTransactionsAccordingToSearchTerm:
                if !state.searchTerm.isEmpty && state.searchTerm.count >= 2 {
                    state.searchedTransactionsList.removeAll()

                    // synchronous search
                    state.transactions.forEach { transaction in
                        if checkSearchTerm(state.searchTerm, transaction: transaction, addressBookContacts: state.addressBookContacts) {
                            state.searchedTransactionsList.append(transaction)
                        }
                    }

                    // asynchronous search
                    return .run { [searchTerm = state.searchTerm] send in
                        let txids = try? await sdkSynchronizer.fetchTxidsWithMemoContaining(searchTerm).map {
                            $0.toHexStringTxId()
                        }
                        
                        if let txids {
                            await send(.asynchronousMemoSearchResult(txids))
                        } else {
                            await send(.updateTransactionsAccordingToFilters)
                        }
                    }
                } else {
                    state.searchedTransactionsList = state.transactions
                }
                
                return .send(.updateTransactionsAccordingToFilters)

            case .asynchronousMemoSearchResult(let txids):
                let results = state.transactions.filter { txids.contains($0.id) }
                state.searchedTransactionsList.append(contentsOf: results)
                return .send(.updateTransactionsAccordingToFilters)
                
            case .updateTransactionsAccordingToFilters:
                // modify the initial list of all transactions according to active filters
                if !state.activeFilters.isEmpty {
                    state.filteredTransactionsList.removeAll()

                    state.searchedTransactionsList.forEach { transaction in
                        var isFilteredOut = false
                        
                        for i in 0..<state.activeFilters.count {
                            let filter = state.activeFilters[i]
                            
                            if !filter.applyFilter(
                                transaction,
                                addressBookContacts: state.addressBookContacts,
                                userMetadataProvider: userMetadataProvider
                            ) {
                                isFilteredOut = true
                                break
                            }
                        }
                        
                        if !isFilteredOut {
                            state.filteredTransactionsList.append(transaction)
                        }
                    }
                } else {
                    state.filteredTransactionsList = state.searchedTransactionsList
                }

                return .send(.updateTransactionPeriods)
                
            case .updateTransactionPeriods:
                state.transactionSections.removeAll()

                // divide the filtered list of transactions into a time periods
                let grouped = Dictionary(grouping: state.filteredTransactionsList) { transaction in
                    guard let timestamp = transaction.timestamp else { return L10n.Filter.today }

                    let calendar = Calendar.current
                    let startOfToday = calendar.startOfDay(for: Date())
                    let startOfGivenDate = calendar.startOfDay(for: Date(timeIntervalSince1970: timestamp))

                    return getTimePeriod(for: startOfGivenDate, now: startOfToday)
                }

                let sections = grouped.map { key, transactions in
                    var timestamp: TimeInterval = Date().timeIntervalSince1970
                    
                    for transaction in transactions {
                        if transaction.timestamp != nil {
                            timestamp = transaction.timestamp ?? 0
                            break
                        }
                    }
                    
                    return Section(
                        id: key,
                        latestTransactionId: transactions.last?.id ?? "",
                        timestamp: timestamp,
                        transactions: IdentifiedArrayOf<TransactionState>(uniqueElements: transactions)
                    )
                }
                
                let sortedSections = sections.sorted { lhs, rhs in
                    lhs.timestamp > rhs.timestamp
                }
                
                sortedSections.forEach { section in
                    state.transactionSections.append(section)
                }

                return .none
                
            case .transactionOnAppear:
                return .none
            }
        }
    }
}

extension TransactionsManager {
    func getTimePeriod(for date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: date, to: now)
        let daysAgo = components.day ?? Int.max
        
        if Calendar.current.isDateInToday(date) {
            return L10n.Filter.today
        } else if Calendar.current.isDateInYesterday(date) {
            return L10n.Filter.yesterday
        } else if daysAgo < 7 {
            return L10n.Filter.previous7days
        } else if daysAgo < 31 {
            return L10n.Filter.previous30days
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: date)
        }
    }
    
    func unicodeContains(_ searchTerm: String, in text: String) -> Bool {
        let normalizedText = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedSearchTerm = searchTerm.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        
        return normalizedText.range(of: normalizedSearchTerm) != nil
    }
    
    func checkSearchTerm(_ searchTerm: String, transaction: TransactionState, addressBookContacts: AddressBookContacts) -> Bool {
        // search contact name
        if addressBookContacts.contacts.contains(where: {
            $0.id == transaction.address && unicodeContains(searchTerm, in: $0.name)
        }) {
            return true
        }
        
        // search address
        if unicodeContains(searchTerm, in: transaction.address) {
            return true
        }

        // Regex amounts
        var input = transaction.zecAmount.decimalString()
        
        if transaction.isSpending {
            input = "-\(input)"
        }
        
        let pattern = "([<>])\\s*(-?(?:0|(?=\\.))?\\d*(?:[.,]\\d+)?)"
        
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: searchTerm, range: NSRange(searchTerm.startIndex..., in: searchTerm)) {
            
            if let operatorRange = Range(match.range(at: 1), in: searchTerm),
               let numberRange = Range(match.range(at: 2), in: searchTerm),
               let threshold = numberFormatter.number(String(searchTerm[numberRange])) {
                let op = String(searchTerm[operatorRange])
                
                if let amount = numberFormatter.number(input) {
                    if op == "<" {
                        return amount.doubleValue < threshold.doubleValue
                    } else if op == ">" {
                        return amount.doubleValue > threshold.doubleValue
                    }
                }
            }
        }
        
        // fullsearch amounts
        if input.contains(searchTerm) {
            return true
        }
        
        // fullsearch annotations
        if let annotation = userMetadataProvider.annotationFor(transaction.id), annotation.contains(searchTerm) {
            return true
        }

        return false
    }
    
}

extension TransactionsManager.Filter {
    func applyFilter(
        _ transaction: TransactionState,
        addressBookContacts: AddressBookContacts,
        userMetadataProvider: UserMetadataProviderClient
    ) -> Bool {
        switch self {
        case .bookmarked:
            return userMetadataProvider.isBookmarked(transaction.id)
        case .contact:
            return addressBookContacts.contacts.contains(where: { $0.address == transaction.address })
        case .memos:
            return transaction.memoCount > 0
        case .notes:
            return userMetadataProvider.annotationFor(transaction.id) != nil
        case .received:
            return !transaction.isSentTransaction
        case .sent:
            return transaction.isSentTransaction
        case .swap:
            return userMetadataProvider.isSwapTransaction(transaction.zAddress ?? "")
        case .unread:
            return true
        }
    }
}

public extension TransactionsManager {
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

        // TODO: remove this refunded hardcoded one
        if transaction.id == "00b61343a47ccf5015fd075054a2500da06380c05513cd776bc74f3545f68cdf" {
            return true
        }

        return userMetadataProvider.isSwapTransaction(transaction.zAddress ?? "")
    }
}
