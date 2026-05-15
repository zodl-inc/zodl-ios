//
//  ReviewRequestTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 04.04.2023.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

@MainActor
final class ReviewRequestTests: XCTestCase {
    func testSyncFinishedPersistency() async throws {
        guard let userDefaults = UserDefaults.init(suiteName: "testSyncFinishedPersistency") else {
            XCTFail("Review Request: UserDefaults failed to initialize")
            return
        }
        
        let store = TestStore(
            initialState: .initial
        ) {
            Home()
        }
        
        let now = Date.now
        let userDefaultsClient: UserDefaultsClient = .live(userDefaults: userDefaults)
        
        store.dependencies.reviewRequest =
            .live(
                appVersion: .mock,
                date: DateClient(
                    now: { now }
                ),
                userDefaults: userDefaultsClient
            )
        
        var syncState: SynchronizerState = .zero
        syncState.syncStatus = .upToDate
        
        await store.send(.synchronizerStateChanged(syncState.redacted))
        
        let storedDate = userDefaultsClient.objectForKey(ReviewRequestClient.Constants.latestSyncKey) as? TimeInterval
        XCTAssertEqual(now.timeIntervalSince1970, storedDate, "Review Request: stored date doesn't match the input.")
    }
    
    func testFoundTransactionsPersistency() async throws {
        guard let userDefaults = UserDefaults.init(suiteName: "testFoundTransactionsPersistency") else {
            XCTFail("Review Request: UserDefaults failed to initialize")
            return
        }

        let store = TestStore(
            initialState: .initial
        ) {
            Home()
        }

        let now = Date.now
        let userDefaultsClient: UserDefaultsClient = .live(userDefaults: userDefaults)

        userDefaultsClient.setValue("any value", ReviewRequestClient.Constants.latestSyncKey)

        store.dependencies.reviewRequest =
            .live(
                appVersion: .mock,
                date: DateClient(
                    now: { now }
                ),
                userDefaults: userDefaultsClient
            )

        await store.send(.foundTransactions)

        let storedDate = userDefaultsClient.objectForKey(ReviewRequestClient.Constants.foundTransactionsKey) as? TimeInterval
        XCTAssertEqual(now.timeIntervalSince1970, storedDate, "Review Request: stored date doesn't match the input.")
    }
    
    func testCanRequestReview_FirstTime() throws {
        guard let userDefaults = UserDefaults.init(suiteName: "testCanRequestReview_FirstTime") else {
            XCTFail("Review Request: UserDefaults failed to initialize")
            return
        }

        let now = Date.now
        let userDefaultsClient: UserDefaultsClient = .live(userDefaults: userDefaults)

        userDefaultsClient.setValue("any value", ReviewRequestClient.Constants.latestSyncKey)
        userDefaultsClient.setValue("any value", ReviewRequestClient.Constants.foundTransactionsKey)

        let reviewRequest = ReviewRequestClient.live(
            appVersion: .mock,
            date: DateClient(
                now: { now }
            ),
            userDefaults: userDefaultsClient
        )
        
        XCTAssertTrue(reviewRequest.canRequestReview())
    }
    
    func testCanRequestReview_NewerVersion() throws {
        guard let userDefaults = UserDefaults.init(suiteName: "testCanRequestReview_NewerVersion") else {
            XCTFail("Review Request: UserDefaults failed to initialize")
            return
        }

        let now = Date.now
        let userDefaultsClient: UserDefaultsClient = .live(userDefaults: userDefaults)

        userDefaultsClient.setValue("any value", ReviewRequestClient.Constants.latestSyncKey)
        userDefaultsClient.setValue("any value", ReviewRequestClient.Constants.foundTransactionsKey)
        userDefaultsClient.setValue("0.0.1", ReviewRequestClient.Constants.versionKey)

        let reviewRequest = ReviewRequestClient.live(
            appVersion: AppVersionClient(
                appVersion: { "0.0.2" },
                appBuild: { "1" }
            ),
            date: DateClient(
                now: { now }
            ),
            userDefaults: userDefaultsClient
        )
        
        XCTAssertTrue(reviewRequest.canRequestReview())
    }
    
    func testCanRequestReview_OlderVersion() throws {
        guard let userDefaults = UserDefaults.init(suiteName: "testCanRequestReview_OlderVersion") else {
            XCTFail("Review Request: UserDefaults failed to initialize")
            return
        }

        let now = Date.now
        let userDefaultsClient: UserDefaultsClient = .live(userDefaults: userDefaults)

        userDefaultsClient.setValue("any value", ReviewRequestClient.Constants.latestSyncKey)
        userDefaultsClient.setValue("any value", ReviewRequestClient.Constants.foundTransactionsKey)
        userDefaultsClient.setValue("0.0.2", ReviewRequestClient.Constants.versionKey)

        let reviewRequest = ReviewRequestClient.live(
            appVersion: AppVersionClient(
                appVersion: { "0.0.1" },
                appBuild: { "1" }
            ),
            date: DateClient(
                now: { now }
            ),
            userDefaults: userDefaultsClient
        )
        
        XCTAssertFalse(reviewRequest.canRequestReview())
    }
    
    func testCanRequestReview_MissingSync() throws {
        guard let userDefaults = UserDefaults.init(suiteName: "testCanRequestReview_MissingSync") else {
            XCTFail("Review Request: UserDefaults failed to initialize")
            return
        }

        let now = Date.now
        let userDefaultsClient: UserDefaultsClient = .live(userDefaults: userDefaults)

        let reviewRequest = ReviewRequestClient.live(
            appVersion: .mock,
            date: DateClient(
                now: { now }
            ),
            userDefaults: userDefaultsClient
        )
        
        XCTAssertFalse(reviewRequest.canRequestReview())
    }
    
    func testCanRequestReview_MissingTransaction() throws {
        guard let userDefaults = UserDefaults.init(suiteName: "testCanRequestReview_MissingTransaction") else {
            XCTFail("Review Request: UserDefaults failed to initialize")
            return
        }

        let now = Date.now
        let userDefaultsClient: UserDefaultsClient = .live(userDefaults: userDefaults)

        userDefaultsClient.setValue("any value", ReviewRequestClient.Constants.latestSyncKey)
        userDefaultsClient.setValue("0.0.1", ReviewRequestClient.Constants.versionKey)

        let reviewRequest = ReviewRequestClient.live(
            appVersion: AppVersionClient(
                appVersion: { "0.0.2" },
                appBuild: { "1" }
            ),
            date: DateClient(
                now: { now }
            ),
            userDefaults: userDefaultsClient
        )
        
        XCTAssertFalse(reviewRequest.canRequestReview())
    }
}
