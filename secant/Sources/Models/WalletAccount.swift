//
//  WalletAccount.swift
//  modules
//
//  Created by Lukáš Korba on 26.11.2024.
//

import SwiftUI
@preconcurrency import ZcashLightClientKit

struct WalletAccount: Equatable, Hashable, Codable, Identifiable {
    enum Vendor: Int, Equatable, Codable, Hashable {
        case keystone = 0
        case zcash
        case ledger = 2

        func icon() -> Image {
            switch self {
            case .keystone:
                return Asset.Assets.Partners.keystoneLogo.image
            case .zcash:
                return Asset.Assets.Icons.zashiLogoSq.image
            case .ledger:
                return Asset.Assets.Partners.ledgerLogo.image
            }
        }

        func isDefault() -> Bool {
            self == .zcash
        }

        func isHWWallet() -> Bool {
            self != .zcash
        }

        func name() -> String {
            switch self {
            case .keystone:
                return String(localizable: .accountsKeystone)
            case .zcash:
                return String(localizable: .accountsZashi)
            case .ledger:
                return String(localizable: .accountsLedger)
            }
        }

        /// Display order for account lists: Zodl first, then Keystone, then Ledger.
        /// This is deliberately not `rawValue` — `rawValue` is a stable Codable identity for the
        /// vendor, not an ordering, and must not be repurposed as one.
        var sortOrder: Int {
            switch self {
            case .zcash:
                return 0
            case .keystone:
                return 1
            case .ledger:
                return 2
            }
        }
    }

    let id: AccountUUID
    let vendor: Vendor
    var defaultUA: UnifiedAddress?
    var privateUA: UnifiedAddress?
    /// The pre-generated rotation stash — a fresh UA allocated ahead of time and never displayed.
    /// A Receive/Swap tap promotes it into `privateUA` synchronously and refills this slot in the
    /// background, so a visit never waits on the wallet-DB write nor re-shows an address (MOB-1803).
    var nextPrivateUA: UnifiedAddress?
    var seedFingerprint: [UInt8]?
    var zip32AccountIndex: Zip32AccountIndex?
    let account: Account

    var unifiedAddress: String? {
        defaultUA?.stringEncoded
    }

    var privateUnifiedAddress: String? {
        privateUA?.stringEncoded
    }

    var saplingAddress: String? {
        try? defaultUA?.saplingReceiver().stringEncoded
    }

    var transparentAddress: String? {
        try? defaultUA?.transparentReceiver().stringEncoded
    }

    init(_ account: Account) {
        self.id = account.id
        switch account.keySource?.lowercased() {
        case Account.ledgerKeySource:
            self.vendor = .ledger
        case Account.keystoneKeySource:
            self.vendor = .keystone
        default:
            self.vendor = .zcash
        }
        self.seedFingerprint = account.seedFingerprint
        self.zip32AccountIndex = account.hdAccountIndex
        self.account = account
    }

    /// Stable sort of `accounts` by `Vendor.sortOrder` (Zodl, Keystone, Ledger), preserving the
    /// relative order of accounts that share a vendor.
    static func sortedByVendor(_ accounts: [WalletAccount]) -> [WalletAccount] {
        accounts.sorted { $0.vendor.sortOrder < $1.vendor.sortOrder }
    }
}
