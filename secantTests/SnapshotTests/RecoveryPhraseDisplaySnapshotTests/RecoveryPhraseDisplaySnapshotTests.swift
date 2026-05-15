//
//  RecoveryPhraseDisplaySnapshotTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 13.06.2022.
//

import XCTest
import ComposableArchitecture
@testable import secant_testnet

class RecoveryPhraseDisplaySnapshotTests: XCTestCase {
    func testRecoveryPhraseDisplaySnapshot() throws {
        let store = StoreOf<RecoveryPhraseDisplay>(
            initialState: .init(phrase: .placeholder)
        ) {
            RecoveryPhraseDisplay()
                .dependency(\.numberFormatter, .noOp)
                .dependency(\.walletStorage, .noOp)
        }
        
        addAttachments(RecoveryPhraseDisplayView(store: store))
    }
}
