//
//  ZcashAccounts.swift
//  KeystoneSDK
//
//  Created by Sora Li on 2024/11/27.
//

import Foundation

public struct ZcashAccounts : Equatable, Codable {
    public var seedFingerprint: String
    public var accounts: Array<ZcashUnifiedFullViewingKey>
}

public struct ZcashUnifiedFullViewingKey: Equatable, Codable {
    public var ufvk: String
    public var index: UInt32
    public var name: String?
}
