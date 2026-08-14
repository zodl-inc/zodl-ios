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

    // MARK: - Migration (Orchard -> Ironwood)
    //
    // PHASE 3 working set, keys verbatim from #1930 so a wallet that ever ran that build reads its
    // own persisted state back. The completion/rounds keys (`migrationCompleteAcknowledged`,
    // `migrationRemainderPending`, `migrationCompletedRounds`) arrive with Phase 6; #1930's
    // `migrationDustLocked` is deliberately NOT carried over at all — it was a cosmetic stand-in
    // that the real `lockMigrationResidual` replaced, and the lock now lives in the account's own
    // `PoolBalance.lockedValue` (matrix B16).
    static let migrationMode = "sharedStateKey_migrationMode"
    /// M3 B2 (MOB-1466): Σ of the received value of the selected account's stored-but-unmined
    /// migration transactions — the figure the balance-breakdown sheet removes from its displayed
    /// "Pending" row. Written by `RootTransactions` in the same canonical pass that builds the
    /// shared transaction list (which now presents those rows as labeled in-flight history), so
    /// the figure and the list can never disagree.
    static let unminedMigrationPendingValue = "sharedStateKey_unminedMigrationPendingValue"
    static let migrationNetworkPrivacyOptions = "sharedStateKey_migrationNetworkPrivacyOptions"
    static let migrationNetworkSnapshot = "sharedStateKey_migrationNetworkSnapshot"
    static let migrationCommittedSchedule = "sharedStateKey_migrationCommittedSchedule"
    static let migrationStoppedSyncForBroadcast = "sharedStateKey_migrationStoppedSyncForBroadcast"
    static let migrationHadBroadcast = "sharedStateKey_migrationHadBroadcast"
    static let migrationBroadcastEpisode = "sharedStateKey_migrationBroadcastEpisode"
    static let migrationTorHold = "sharedStateKey_migrationTorHold"
    static let migrationPendingTorPrompt = "sharedStateKey_migrationPendingTorPrompt"
    // Read/written by storage the manager carries whole from #1930; their SCREENS are Phase 6.
    static let migrationCompleteAcknowledged = "sharedStateKey_migrationCompleteAcknowledged"
    static let migrationRemainderPending = "sharedStateKey_migrationRemainderPending"
    static let migrationCompletedRounds = "sharedStateKey_migrationCompletedRounds"
}
