//
//  ImportWalletSnapshotTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 13.06.2022.
//

import XCTest
import ComposableArchitecture
@testable import zashi_internal

class ImportWalletSnapshotTests: XCTestCase {
    func testImportWalletSnapshot() throws {
        let store = StoreOf<ImportWallet>(
            initialState: .initial
        ) {
            ImportWallet()
        }
        
        addAttachments(ImportWalletView(store: store))
    }
    
    func testImportBirthdaySnapshot() throws {
        let store = StoreOf<ImportWallet>(
            initialState: .initial
        ) {
            ImportWallet()
        }
        
        addAttachments(ImportBirthdayView(store: store))
    }
}
