//
//  NearSignRequest.swift
//  
//
//  Created by Renfeng Shi on 4/26/23.
//

import Foundation

public struct NearSignRequest {
    let requestId: String
    let signData: [String]
    let path: String
    let xfp: String
    let account: String
    let origin: String

    public init(requestId: String, signData: [String], path: String, xfp: String, account: String = "", origin: String = "") {
        self.requestId = requestId
        self.signData = signData
        self.path = path
        self.xfp = xfp
        self.account = account
        self.origin = origin
    }
}
