//
//  TransactionsManagerLogicTests.swift
//  zodlTests
//
//  Batch 5 — transactions. Covers TransactionsManager filtering/search/time-bucketing/unread/swap
//  (Features/TransactionsManager/TransactionsManagerStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite struct TransactionsManagerLogicTests {
    // MARK: - Filter.applyFilter

    @Test func applyFilterCases() {
        let received = tx(isSent: false, memoCount: 1)
        let sent = tx(isSent: true)
        #expect(TransactionsManager.Filter.received.applyFilter(received, addressBookContacts: .empty, userMetadataProvider: provider()))
        #expect(!TransactionsManager.Filter.received.applyFilter(sent, addressBookContacts: .empty, userMetadataProvider: provider()))
        #expect(TransactionsManager.Filter.sent.applyFilter(sent, addressBookContacts: .empty, userMetadataProvider: provider()))
        #expect(TransactionsManager.Filter.memos.applyFilter(received, addressBookContacts: .empty, userMetadataProvider: provider()))
        #expect(!TransactionsManager.Filter.memos.applyFilter(tx(memoCount: 0), addressBookContacts: .empty, userMetadataProvider: provider()))
        #expect(TransactionsManager.Filter.bookmarked.applyFilter(received, addressBookContacts: .empty, userMetadataProvider: provider(isBookmarked: true)))
        #expect(TransactionsManager.Filter.notes.applyFilter(received, addressBookContacts: .empty, userMetadataProvider: provider(annotation: "note")))
        #expect(TransactionsManager.Filter.swap.applyFilter(received, addressBookContacts: .empty, userMetadataProvider: provider(isSwap: true)))
    }

    @Test func unreadFilterMatchesOnlyUnreadTransactions() {
        // Sent and shielding transactions are never "unread".
        #expect(!unread(tx(isSent: true, memoCount: 1), isRead: false))
        #expect(!unread(tx(isShielding: true, memoCount: 1), isRead: false))
        // A received transaction without memos is not unread.
        #expect(!unread(tx(isSent: false, memoCount: 0), isRead: false))
        // A received transaction with memos that has already been read is not unread.
        #expect(!unread(tx(isSent: false, memoCount: 1), isRead: true))
        // A received transaction with memos that has NOT been read is unread.
        #expect(unread(tx(isSent: false, memoCount: 1), isRead: false))
    }

    private func unread(_ transaction: TransactionState, isRead: Bool) -> Bool {
        TransactionsManager.Filter.unread.applyFilter(transaction, addressBookContacts: .empty, userMetadataProvider: provider(isRead: isRead))
    }

    // MARK: - isUnread / isSwap

    @Test func isUnreadGuards() {
        withDependencies {
            $0.userMetadataProvider = provider(isRead: false)
        } operation: {
            #expect(!TransactionsManager.isUnread(tx(isSent: true, memoCount: 1)))      // sent never unread
            #expect(!TransactionsManager.isUnread(tx(isShielding: true, memoCount: 1))) // shielding never unread
            #expect(!TransactionsManager.isUnread(tx(isSent: false, memoCount: 0)))     // no memo
            #expect(TransactionsManager.isUnread(tx(isSent: false, memoCount: 1)))      // received + memo + unread
        }
    }

    @Test func isUnreadFalseWhenAlreadyRead() {
        withDependencies {
            $0.userMetadataProvider = provider(isRead: true)
        } operation: {
            #expect(!TransactionsManager.isUnread(tx(isSent: false, memoCount: 1)))
        }
    }

    @Test func isSwapUsesHardcodedIdAndProvider() {
        withDependencies {
            $0.userMetadataProvider = provider(isSwap: false)
        } operation: {
            #expect(TransactionsManager.isSwap(tx(id: "00b61343a47ccf5015fd075054a2500da06380c05513cd776bc74f3545f68cdf")))
            #expect(!TransactionsManager.isSwap(tx(id: "other")))
        }
        withDependencies {
            $0.userMetadataProvider = provider(isSwap: true)
        } operation: {
            #expect(TransactionsManager.isSwap(tx(id: "other", zAddress: "deposit")))
        }
    }

    // MARK: - getTimePeriod / unicodeContains

    @Test func getTimePeriodBuckets() {
        let manager = TransactionsManager()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(manager.getTimePeriod(for: now.addingTimeInterval(-3 * 86_400), now: now) == String(localizable: .filterPrevious7days))
        #expect(manager.getTimePeriod(for: now.addingTimeInterval(-20 * 86_400), now: now) == String(localizable: .filterPrevious30days))

        let old = now.addingTimeInterval(-60 * 86_400)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        #expect(manager.getTimePeriod(for: old, now: now) == formatter.string(from: old))
    }

    @Test func unicodeContainsIsCaseAndDiacriticInsensitive() {
        let manager = TransactionsManager()
        #expect(manager.unicodeContains("cafe", in: "Café Münchner"))
        #expect(manager.unicodeContains("ALICE", in: "alice cooper"))
        #expect(!manager.unicodeContains("xyz", in: "abcdef"))
    }

    // MARK: - checkSearchTerm

    @Test func checkSearchTermMatchesAddress() {
        withDependencies(prepareSearchDependencies) {
            let manager = TransactionsManager()
            let transaction = tx(isSent: false, zAddress: "u1someaddress")
            #expect(manager.checkSearchTerm("someaddr", transaction: transaction, addressBookContacts: .empty))
        }
    }

    @Test func checkSearchTermAmountThreshold() {
        withDependencies(prepareSearchDependencies) {
            let manager = TransactionsManager()
            let transaction = tx(isSent: false, zecAmount: Zatoshi(100_000_000)) // 1 ZEC
            #expect(manager.checkSearchTerm("<5", transaction: transaction, addressBookContacts: .empty))
            #expect(!manager.checkSearchTerm(">5", transaction: transaction, addressBookContacts: .empty))
        }
    }

    // MARK: - Helpers

    private func prepareSearchDependencies(_ dependencies: inout DependencyValues) {
        dependencies.numberFormatter.number = { string in
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 8
            return formatter.number(from: string)
        }
        dependencies.userMetadataProvider = provider()
    }

    private func provider(
        isBookmarked: Bool = false,
        annotation: String? = nil,
        isSwap: Bool = false,
        isRead: Bool = true
    ) -> UserMetadataProviderClient {
        var client = UserMetadataProviderClient()
        client.isBookmarked = { _ in isBookmarked }
        client.annotationFor = { _ in annotation }
        client.isSwapTransaction = { _ in isSwap }
        client.isRead = { _, _ in isRead }
        return client
    }

    private func tx(
        id: String = "tx-id",
        isSent: Bool = false,
        isShielding: Bool = false,
        memoCount: Int = 0,
        zAddress: String? = nil,
        zecAmount: Zatoshi = Zatoshi(100_000_000)
    ) -> TransactionState {
        TransactionState(
            memoCount: memoCount,
            zAddress: zAddress,
            fee: Zatoshi(10_000),
            id: id,
            status: isSent ? .paid : .received,
            zecAmount: zecAmount,
            isSentTransaction: isSent,
            isShieldingTransaction: isShielding
        )
    }
}
