//
//  TronSignature.swift
//  
//
//  Created by LiYan on 4/12/23.
//

import Foundation

public struct TronSignRequest {
    let requestId: String
    let signData: String
    let path: String
    let xfp: String
    var tokenInfo: TokenInfo?
    var origin: String

    public init(requestId: String, signData: String, path: String, xfp: String, tokenInfo: TokenInfo? = nil, address: String = "", origin: String = "") {
        self.requestId = requestId
        self.signData = signData
        self.path = path
        self.xfp = xfp
        self.tokenInfo = tokenInfo
        self.origin = origin
    }
}
