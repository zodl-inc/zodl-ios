//
//  HDPath.swift
//  
//
//  Created by LiYan on 8/21/23.
//

import Foundation

public struct PathItem: Codable, Equatable {
    let index: UInt32
    let hardened: Bool
    
    public init(index: UInt32, hardened: Bool) {
        self.index = index
        self.hardened = hardened
    }
}

public struct HDPath: Codable {
    let purpose: PathItem?
    let coinType: PathItem?
    let account: PathItem?
    let change: PathItem?
    let addressIndex: PathItem?

    public init(purpose: PathItem?, coinType: PathItem?, account: PathItem?, change: PathItem?, addressIndex: PathItem?) {
        self.purpose = purpose
        self.coinType = coinType
        self.account = account
        self.change = change
        self.addressIndex = addressIndex
    }
}
