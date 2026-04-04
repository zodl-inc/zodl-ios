//
//  PIRSpendabilityTests.swift
//  secantTests
//
//  Created by Roman on 2026-04-03.
//

import XCTest
import Combine
import ComposableArchitecture
import Root
import Models
@testable import secant_testnet
@testable import ZcashLightClientKit

@MainActor
class PIRSpendabilityTests: XCTestCase {

    // MARK: - checkSpendabilityPIR

    func testCheckSpendabilityPIR_Success() async throws {
        let expectedResult = SpendabilityResult(
            earliestHeight: 100,
            latestHeight: 200,
            spentNoteIds: [1, 2],
            totalSpentValue: 50_000
        )

        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        store.exhaustivity = .off

        store.dependencies.sdkSynchronizer = .noOp
        store.dependencies.sdkSynchronizer.checkWalletSpendability = { _, _ in expectedResult }

        await store.send(.initialization(.checkSpendabilityPIR))

        await store.receive(.initialization(.checkSpendabilityPIRResult(expectedResult))) { state in
            state.pirSpendabilityResult = expectedResult
        }
    }

    func testCheckSpendabilityPIR_Failure() async throws {
        struct PIRError: Error {}

        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        store.exhaustivity = .off

        store.dependencies.sdkSynchronizer = .noOp
        store.dependencies.sdkSynchronizer.checkWalletSpendability = { _, _ in throw PIRError() }

        await store.send(.initialization(.checkSpendabilityPIR))

        await store.receive(.initialization(.checkSpendabilityPIRResult(nil)))
    }

    func testCheckSpendabilityPIRResult_TriggersTransactionRefresh() async throws {
        let result = SpendabilityResult(
            earliestHeight: 100,
            latestHeight: 200,
            spentNoteIds: [1],
            totalSpentValue: 10_000
        )

        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        store.exhaustivity = .off

        store.dependencies.sdkSynchronizer = .noOp

        await store.send(.initialization(.checkSpendabilityPIRResult(result))) { state in
            state.pirSpendabilityResult = result
        }

        await store.receive(.fetchTransactionsForTheSelectedAccount)
        await store.receive(.home(.walletBalances(.updateBalances)))
    }

    // MARK: - foundTransactions / syncReachedUpToDate trigger PIR

    func testFoundTransactions_TriggersPIRCheck() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        store.exhaustivity = .off

        store.dependencies.sdkSynchronizer = .noOp

        await store.send(.foundTransactions([]))

        await store.receive(.fetchTransactionsForTheSelectedAccount)
        await store.receive(.initialization(.checkSpendabilityPIR))
    }

    func testSyncReachedUpToDate_TriggersPIRCheck() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        store.exhaustivity = .off

        store.dependencies.sdkSynchronizer = .noOp

        await store.send(.syncReachedUpToDate)

        await store.receive(.fetchTransactionsForTheSelectedAccount)
        await store.receive(.initialization(.checkSpendabilityPIR))
    }

    // MARK: - fetchedTransactions with PIR placeholder

    func testFetchedTransactions_WithPIRPendingSpends_IncludesPlaceholder() async throws {
        let pirPending = PIRPendingSpends(
            notes: [PIRPendingNote(noteId: 42, value: 25_000)],
            totalValue: 25_000
        )

        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        store.exhaustivity = .off

        store.dependencies.sdkSynchronizer = .noOp

        await store.send(.fetchedTransactions([], pirPending)) { state in
            XCTAssertTrue(state.transactions.contains(where: { $0.isPIRDetectedSpend }))

            let pirTx = state.transactions.first(where: { $0.isPIRDetectedSpend })
            XCTAssertEqual(pirTx?.zecAmount, Zatoshi(-25_000))
        }
    }

    func testFetchedTransactions_WithoutPIRPendingSpends_NoPlaceholder() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        store.exhaustivity = .off

        store.dependencies.sdkSynchronizer = .noOp

        await store.send(.fetchedTransactions([], nil)) { state in
            XCTAssertFalse(state.transactions.contains(where: { $0.isPIRDetectedSpend }))
        }
    }

    func testFetchedTransactions_WithEmptyPIRNotes_NoPlaceholder() async throws {
        let pirPending = PIRPendingSpends(notes: [], totalValue: 0)

        let store = TestStore(
            initialState: .initial
        ) {
            Root()
        }
        store.exhaustivity = .off

        store.dependencies.sdkSynchronizer = .noOp

        await store.send(.fetchedTransactions([], pirPending)) { state in
            XCTAssertFalse(state.transactions.contains(where: { $0.isPIRDetectedSpend }))
        }
    }
}
