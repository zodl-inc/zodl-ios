//
//  ReviewRequestTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 04.04.2023.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@MainActor
@Suite struct ReviewRequestTests {
    @Test func syncFinishedPersistency() async throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testSyncFinishedPersistency"),
            "Review Request: UserDefaults failed to initialize"
        )

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
        #expect(now.timeIntervalSince1970 == storedDate, "Review Request: stored date doesn't match the input.")
    }

    @Test func foundTransactionsPersistency() async throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testFoundTransactionsPersistency"),
            "Review Request: UserDefaults failed to initialize"
        )

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
        #expect(now.timeIntervalSince1970 == storedDate, "Review Request: stored date doesn't match the input.")
    }

    @Test func canRequestReview_FirstTime() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testCanRequestReview_FirstTime"),
            "Review Request: UserDefaults failed to initialize"
        )

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

        #expect(reviewRequest.canRequestReview())
    }

    @Test func canRequestReview_NewerVersion() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testCanRequestReview_NewerVersion"),
            "Review Request: UserDefaults failed to initialize"
        )

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

        #expect(reviewRequest.canRequestReview())
    }

    @Test func canRequestReview_OlderVersion() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testCanRequestReview_OlderVersion"),
            "Review Request: UserDefaults failed to initialize"
        )

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

        #expect(!reviewRequest.canRequestReview())
    }

    @Test func canRequestReview_MissingSync() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testCanRequestReview_MissingSync"),
            "Review Request: UserDefaults failed to initialize"
        )

        let now = Date.now
        let userDefaultsClient: UserDefaultsClient = .live(userDefaults: userDefaults)

        let reviewRequest = ReviewRequestClient.live(
            appVersion: .mock,
            date: DateClient(
                now: { now }
            ),
            userDefaults: userDefaultsClient
        )

        #expect(!reviewRequest.canRequestReview())
    }

    @Test func canRequestReview_MissingTransaction() throws {
        let userDefaults = try #require(
            UserDefaults(suiteName: "testCanRequestReview_MissingTransaction"),
            "Review Request: UserDefaults failed to initialize"
        )

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

        #expect(!reviewRequest.canRequestReview())
    }
}
