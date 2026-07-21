//
//  SharedStateKeys.swift
//
//
//  Created by Lukáš Korba on 05-09-2024
//

import Foundation

public extension String {
    static let exchangeRate = "sharedStateKey_exchangeRate"
    static let sensitiveContent = "udHideBalances"
    static let walletStatus = "sharedStateKey_walletStatus"
    static let flexaAccountId = "sharedStateKey_flexaAccountId"
    static let addressBookContacts = "sharedStateKey_addressBookContacts"
    static let toast = "sharedStateKey_toast"
    static let featureFlags = "sharedStateKey_featureFlags"
    static let lastAuthenticationTimestamp = "sharedStateKey_lastAuthenticationTimestamp"
    static let walletAccounts = "sharedStateKey_walletAccounts"
    static let selectedWalletAccount = "sharedStateKey_selectedWalletAccount"
    static let zashiWalletAccount = "sharedStateKey_zashiWalletAccount"
    static let transactions = "sharedStateKey_transactions"
    static let transactionMemos = "sharedStateKey_transactionMemos"
    static let swapAssets = "sharedStateKey_swapAssets"
    static let swapAssetsCatalog = "sharedStateKey_swapAssetsCatalog"
    static let swapAPIAccess = "sharedStateKey_swapAPIAccess"
    static let hasSeenHowToVote = "sharedStateKey_hasSeenHowToVote"
    static let hasSeenHowToVoteKeystone = "sharedStateKey_hasSeenHowToVoteKeystone"
    static let votingConfigOverrideURL = "sharedStateKey_votingConfigOverrideURL"
    static let votingCustomChains = "sharedStateKey_votingCustomChains"
    static let migrationMode = "sharedStateKey_migrationMode"
    static let migrationManualDelivery = "sharedStateKey_migrationManualDelivery"
    static let migrationNetworkPrivacyOptions = "sharedStateKey_migrationNetworkPrivacyOptions"
    static let migrationCompleteAcknowledged = "sharedStateKey_migrationCompleteAcknowledged"
    static let migrationRemainderPending = "sharedStateKey_migrationRemainderPending"
    static let migrationDustLocked = "sharedStateKey_migrationDustLocked"
    static let migrationCompletedRounds = "sharedStateKey_migrationCompletedRounds"
    static let migrationLastSyncCompletedAt = "sharedStateKey_migrationLastSyncCompletedAt"
    static let migrationCommittedSchedule = "sharedStateKey_migrationCommittedSchedule"
    static let migrationStoppedSyncForBroadcast = "sharedStateKey_migrationStoppedSyncForBroadcast"
    static let migrationNetworkSnapshot = "sharedStateKey_migrationNetworkSnapshot"
    static let migrationSendWaitActive = "sharedStateKey_migrationSendWaitActive"
    static let migrationHadBroadcast = "sharedStateKey_migrationHadBroadcast"
    static let migrationBroadcastEpisode = "sharedStateKey_migrationBroadcastEpisode"
    static let migrationTorHold = "sharedStateKey_migrationTorHold"
    static let migrationPendingTorPrompt = "sharedStateKey_migrationPendingTorPrompt"
}
