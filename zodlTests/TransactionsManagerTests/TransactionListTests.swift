//
//  TransactionListTests.swift
//  zodlTests
//
//  Batch 5 — transactions. Covers TransactionList home-page truncation + isUnread/isSwap
//  (Features/TransactionList/TransactionListStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct TransactionListTests {
    @MainActor @Test func transactionsUpdatedTakesHomePagePrefix() async {
        var state = TransactionList.State()
        let txs = (0..<7).map { tx(id: "tx\($0)") }
        state.$transactions.withLock { $0 = IdentifiedArrayOf(uniqueElements: txs) }

        let store = TestStore(initialState: state) { TransactionList() }
        store.exhaustivity = .off
        await store.send(.transactionsUpdated)

        #expect(store.state.transactionListHomePage.count == 5)
        #expect(store.state.latestTransactionId == "tx4") // 5th element
        #expect(!store.state.isInvalidated)
    }

    @MainActor @Test func transactionTappedMarksUnreadReceivedAsRead() async {
        let readCalls = LockIsolated<[String]>([])
        var state = TransactionList.State()
        state.$transactions.withLock { $0 = IdentifiedArrayOf(uniqueElements: [tx(id: "unread", memoCount: 1)]) }

        let store = TestStore(initialState: state) { TransactionList() } withDependencies: {
            $0.userMetadataProvider = provider(isRead: false)
            $0.userMetadataProvider.readTx = { id in readCalls.withValue { $0.append(id) } }
        }
        await store.send(.transactionTapped("unread"))

        #expect(readCalls.value == ["unread"])
    }

    @MainActor @Test func transactionTappedDoesNotMarkAlreadyReadTransaction() async {
        let readCalls = LockIsolated<[String]>([])
        var state = TransactionList.State()
        state.$transactions.withLock { $0 = IdentifiedArrayOf(uniqueElements: [tx(id: "read", memoCount: 1)]) }

        let store = TestStore(initialState: state) { TransactionList() } withDependencies: {
            $0.userMetadataProvider = provider(isRead: true)
            $0.userMetadataProvider.readTx = { id in readCalls.withValue { $0.append(id) } }
        }
        await store.send(.transactionTapped("read"))

        #expect(readCalls.value.isEmpty)
    }

    @MainActor @Test func transactionTappedUnknownIdIsNoOp() async {
        let readCalls = LockIsolated<[String]>([])
        var state = TransactionList.State()
        state.$transactions.withLock { $0 = IdentifiedArrayOf(uniqueElements: [tx(id: "present", memoCount: 1)]) }

        let store = TestStore(initialState: state) { TransactionList() } withDependencies: {
            $0.userMetadataProvider = provider(isRead: false)
            $0.userMetadataProvider.readTx = { id in readCalls.withValue { $0.append(id) } }
        }
        await store.send(.transactionTapped("missing"))

        #expect(readCalls.value.isEmpty)
    }

    @Test func isUnreadGuards() {
        withDependencies {
            $0.userMetadataProvider = provider(isRead: false)
        } operation: {
            #expect(!TransactionList.isUnread(tx(isSent: true, memoCount: 1)))
            #expect(!TransactionList.isUnread(tx(isShielding: true, memoCount: 1)))
            #expect(!TransactionList.isUnread(tx(memoCount: 0)))
            #expect(TransactionList.isUnread(tx(memoCount: 1)))
        }
    }

    @Test func isSwapUsesProvider() {
        withDependencies {
            $0.userMetadataProvider = provider(isSwap: true)
        } operation: {
            #expect(TransactionList.isSwap(tx(zAddress: "deposit")))
        }
    }

    private func provider(isSwap: Bool = false, isRead: Bool = true) -> UserMetadataProviderClient {
        var client = UserMetadataProviderClient()
        client.isSwapTransaction = { _ in isSwap }
        client.isRead = { _, _ in isRead }
        return client
    }

    private func tx(
        id: String = "tx-id",
        isSent: Bool = false,
        isShielding: Bool = false,
        memoCount: Int = 0,
        zAddress: String? = nil
    ) -> TransactionState {
        TransactionState(
            memoCount: memoCount,
            zAddress: zAddress,
            fee: Zatoshi(10_000),
            id: id,
            status: isSent ? .paid : .received,
            zecAmount: Zatoshi(100_000_000),
            isSentTransaction: isSent,
            isShieldingTransaction: isShielding
        )
    }
}
