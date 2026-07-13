//
//  KeystoneSignRequest.swift
//  
//
//  Created by LiYan on 4/21/23.
//

import Foundation

public struct KeystoneSignRequest<T: Codable>: Codable {
    let requestId: String
    let signData: T
    let xfp: String
    var origin: String

    public init(requestId: String, signData: T, xfp: String, origin: String = "") {
        self.requestId = requestId
        self.signData = signData
        self.xfp = xfp
        self.origin = origin
    }
}
