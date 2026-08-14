//
//  TransactionDetailsMemosTests.swift
//  zodlTests
//
//  Covers MOB-1593: post-NU6.3 transactions can contain fabricated zero-value outputs
//  whose on-chain memo is 512 bytes of 0x00. Per ZIP-302 the Zcash Swift SDK parses that
//  as a *text* memo whose string is "" (not nil), so `.memosLoaded` must drop exactly-empty
//  memo strings — otherwise the app shows an extra, empty "Message" bubble
//  (Features/TransactionDetails/TransactionDetailsStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct TransactionDetailsMemosTests {
    @Test @MainActor func memosLoadedDropsEmptyTextMemos() async throws {
        // Pins the ZIP-302 premise: an all-zero 512-byte memo parses as a text memo
        // whose string is "" — not nil. If this ever stops holding, the rest of this
        // test no longer exercises the bug it's meant to guard against.
        let allZeroMemo = try Memo(bytes: [UInt8](repeating: 0, count: 512))
        let allZeroMemoString = try #require(allZeroMemo.toString())
        #expect(allZeroMemoString.isEmpty)

        let transaction = TransactionState.placeholder(uuid: "tx-id")
        let store = TestStore(initialState: TransactionDetails.State(transaction: transaction)) {
            TransactionDetails()
        }

        await store.send(.memosLoaded([allZeroMemo, try Memo(string: "Testing"), Memo.empty])) { state in
            state.areMessagesResolved = true
            state.$transactionMemos.withLock { $0[transaction.id] = ["Testing"] }
            state.messageStates = [.short]
        }
    }
}
