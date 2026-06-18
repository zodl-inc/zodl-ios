//
//  Account.swift
//  
//
//  Created by LiYan on 6/5/23.
//

import Foundation

public enum AccountNote: String {
    case standard = "account.standard"
    case ledgerLegacy = "account.ledger_legacy"
    case ledgerLive = "account.ledger_live"
}

public struct OKXExtra: Equatable, Codable {
    public var chainId: Int
}

public struct Extra: Equatable, Codable {
    public var okx: OKXExtra
}

public struct Account : Equatable, Codable {
    public var chain: String
    public var path: String
    public var publicKey: String
    public var name: String
    public var chainCode: String
    public var extendedPublicKey: String
    public var note: String?
    public var extra: Extra
}
