//
//  DatabaseFilesTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 07.04.2022.
//

import XCTest
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

class DatabaseFilesTests: XCTestCase {
    let network = ZcashNetworkBuilder.network(for: .testnet)
    
    func testDatabaseFilesPresent() throws {
        let mockedFileManager = FileManagerClient(
            url: { _, _, _, _ in .emptyURL },
            fileExists: { _ in return true },
            removeItem: { _ in }
        )
        
        let dfInteractor = DatabaseFilesClient.live(databaseFiles: DatabaseFiles(fileManager: mockedFileManager))
        let areFilesPresent = dfInteractor.areDbFilesPresentFor(network)
        XCTAssertTrue(areFilesPresent, "DatabaseFiles: `testDatabaseFilesPresent` is expected to be true but it's \(areFilesPresent)")
    }

    func testDatabaseFilesNotPresent() throws {
        let mockedFileManager = FileManagerClient(
            url: { _, _, _, _ in .emptyURL },
            fileExists: { _ in return false },
            removeItem: { _ in }
        )
        
        let dfInteractor = DatabaseFilesClient.live(databaseFiles: DatabaseFiles(fileManager: mockedFileManager))
        let areFilesPresent = dfInteractor.areDbFilesPresentFor(network)
        XCTAssertFalse(areFilesPresent, "DatabaseFiles: `testDatabaseFilesNotPresent` is expected to be false but it's \(areFilesPresent)")
    }
}
