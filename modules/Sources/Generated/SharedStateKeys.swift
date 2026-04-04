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
    static let swapAPIAccess = "sharedStateKey_swapAPIAccess"
    static let pirSpendabilityResult = "sharedStateKey_pirSpendabilityResult"
}
