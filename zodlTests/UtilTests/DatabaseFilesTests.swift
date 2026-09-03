//
//  DatabaseFilesTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 07.04.2022.
//

import Testing
@preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite struct DatabaseFilesTests {
    let network = ZcashNetworkBuilder.network(for: .testnet)

    @Test func databaseFilesPresent() throws {
        let mockedFileManager = FileManagerClient(
            url: { _, _, _, _ in .emptyURL },
            fileExists: { _ in return true },
            removeItem: { _ in }
        )

        let dfInteractor = DatabaseFilesClient.live(databaseFiles: DatabaseFiles(fileManager: mockedFileManager))
        let areFilesPresent = dfInteractor.areDbFilesPresentFor(network)
        #expect(areFilesPresent, "DatabaseFiles: `testDatabaseFilesPresent` is expected to be true but it's \(areFilesPresent)")
    }

    @Test func databaseFilesNotPresent() throws {
        let mockedFileManager = FileManagerClient(
            url: { _, _, _, _ in .emptyURL },
            fileExists: { _ in return false },
            removeItem: { _ in }
        )

        let dfInteractor = DatabaseFilesClient.live(databaseFiles: DatabaseFiles(fileManager: mockedFileManager))
        let areFilesPresent = dfInteractor.areDbFilesPresentFor(network)
        #expect(!areFilesPresent, "DatabaseFiles: `testDatabaseFilesNotPresent` is expected to be false but it's \(areFilesPresent)")
    }
}
