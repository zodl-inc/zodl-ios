//
//  TokenInfo.swift
//  
//
//  Created by LiYan on 4/12/23.
//

import Foundation

public struct TokenInfo: Encodable {
    let name: String
    let symbol: String
    let decimals: Int32

    public init(name: String, symbol: String, decimals: Int32) {
        self.name = name
        self.symbol = symbol
        self.decimals = decimals
    }
}
