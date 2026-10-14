//
//  TransactionsCoordFlowCoordinatorTests.swift
//  zodlTests
//
//  Extended — coordinator nav. Covers TransactionsCoordFlow.coordinatorReduce routing
//  (Features/CoordFlows/TransactionsCoordFlowCoordinator.swift).
//

import Testing
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZODLSwiftWalletSDK

@Suite(.serialized) struct TransactionsCoordFlowCoordinatorTests {
    @Test func transactionTappedPushesTransactionDetailsForThatTransaction() {
        var state = TransactionsCoordFlow.State()
        state.$transactions.withLock { $0 = [tx(id: "txA"), tx(id: "txB")] }

        _ = TransactionsCoordFlow().coordinatorReduce().reduce(
            into: &state,
            action: .transactionsManager(.transactionTapped("txB"))
        )

        #expect(state.path.count == 1)
        if case let .transactionDetails(details)? = state.path.last {
            #expect(details.transaction.id == "txB")
        } else {
            Issue.record("expected transactionDetails on the path")
        }
    }

    @Test func saveAddressTappedPushesAddressBookContactSeededFromTransaction() {
        var state = TransactionsCoordFlow.State()
        state.transactionDetailsState.transaction = tx(id: "txC", zAddress: "u1recipient")

        _ = TransactionsCoordFlow().coordinatorReduce().reduce(
            into: &state,
            action: .transactionDetails(.saveAddressTapped)
        )

        #expect(state.path.count == 1)
        if case let .addressBookContact(addressBook)? = state.path.last {
            #expect(addressBook.address == "u1recipient")
            #expect(addressBook.context == .send)
            #expect(addressBook.isValidZcashAddress)
        } else {
            Issue.record("expected addressBookContact on the path")
        }
    }

    private func tx(id: String, zAddress: String? = nil) -> TransactionState {
        TransactionState(zAddress: zAddress, fee: Zatoshi(10_000), id: id, status: .received, zecAmount: Zatoshi(100_000_000))
    }
}
