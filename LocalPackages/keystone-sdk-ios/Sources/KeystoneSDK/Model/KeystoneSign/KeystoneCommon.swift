//
//  KeystoneCommon.swift
//  
//
//  Created by LiYan on 4/21/23.
//

import Foundation

public struct Input: Codable {
    let hash: String
    let index: Int32
    let value: Int64
    let memo: String
    let pubkey: String
    var ownerKeyPath: String

    public init(hash: String, index: Int32, value: Int64, memo: String = "", pubkey: String, ownerKeyPath: String) {
        self.hash = hash
        self.index = index
        self.value = value
        self.memo = memo
        self.pubkey = pubkey
        self.ownerKeyPath = ownerKeyPath
    }
}


public struct Output: Codable {
    let address: String
    let value: Int64
    let isChange: Bool
    let changeAddressPath: String

    public init(address: String, value: Int64, isChange: Bool = false, changeAddressPath: String = "") {
        self.address = address
        self.value = value
        self.isChange = isChange
        self.changeAddressPath = changeAddressPath
    }
}

public struct TransactionSignResult: Codable {
    public var requestId: String
    public var rawData: String

    public init(requestId: String, rawData: String) {
        self.requestId = requestId
        self.rawData = rawData
    }
}
