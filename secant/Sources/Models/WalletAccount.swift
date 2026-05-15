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
        
        func icon() -> Image {
            switch self {
            case .keystone:
                return Asset.Assets.Partners.keystoneLogo.image
            case .zcash:
                return Asset.Assets.Icons.zashiLogoSq.image
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
            }
        }
    }

    let id: AccountUUID
    let vendor: Vendor
    var defaultUA: UnifiedAddress?
    var privateUA: UnifiedAddress?
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
        self.vendor = account.keySource == String(localizable: .accountsKeystone).lowercased() ? .keystone : .zcash
        self.seedFingerprint = account.seedFingerprint
        self.zip32AccountIndex = account.hdAccountIndex
        self.account = account
    }
}
