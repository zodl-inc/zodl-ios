//
//  ReviewRequestLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 3.4.2023.
//

import Foundation
import ComposableArchitecture

extension ReviewRequestClient: DependencyKey {
    static let liveValue = ReviewRequestClient.live()
    
    static func live(
        appVersion: AppVersionClient = .liveValue,
        date: DateClient = .liveValue,
        userDefaults: UserDefaultsClient = .live()
    ) -> Self {
        Self(
            canRequestReview: {
                // set of conditions that must be fulfilled in order to trigger review request
                
                // the wallet must be synced
                guard userDefaults.objectForKey(Constants.latestSyncKey) != nil else { return false }
                
                // the version is ether nil or latest review is from some older version
                let currentVersion = appVersion.appVersion()
                if let storedVersion = userDefaults.objectForKey(Constants.versionKey) as? String {
                    guard currentVersion.compare(storedVersion, options: .numeric) == .orderedDescending else {
                        return false
                    }
                }
                
                // there has been at least one found transaction since the very first sync
                guard userDefaults.objectForKey(Constants.foundTransactionsKey) != nil else { return false }
                
                return true
            },
            foundTransactions: {
                // only if there's the very first sync stored
                guard userDefaults.objectForKey(Constants.latestSyncKey) != nil else { return }
                userDefaults.setValue(date.now().timeIntervalSince1970, Constants.foundTransactionsKey)
            },
            reviewRequested: {
                // the review has been requested, update the version and timestamp
                userDefaults.setValue(date.now().timeIntervalSince1970, Constants.reviewRequestedKey)
                userDefaults.setValue(appVersion.appVersion(), Constants.versionKey)
            },
            syncFinished: {
                // synchronizer's sync has been finished successfuly
                userDefaults.setValue(date.now().timeIntervalSince1970, Constants.latestSyncKey)
            }
        )
    }
}

extension ReviewRequestClient {
    enum Constants: CaseIterable {
        static let foundTransactionsKey = "ReviewRequestClient.foundTransactions"
        static let latestSyncKey = "ReviewRequestClient.latestSyncKey"
        static let reviewRequestedKey = "ReviewRequestClient.reviewRequestedKey"
        static let versionKey = "ReviewRequestClient.versionKey"
    }
}
