//
//  SolSignRequest.swift
//  
//
//  Created by LiYan on 3/29/23.
//

import Foundation

public struct SolSignRequest {
    let requestId: String
    let signData: String
    let path: String
    let xfp: String
    let signType: SignType
    let address: String
    let origin: String

    public enum SignType: Int32 {
        case transaction = 1
        case message = 2
    }

    public init(requestId: String, signData: String, path: String, xfp: String, signType: SignType, address: String = "", origin: String = "") {
        self.requestId = requestId
        self.signData = signData
        self.path = path
        self.xfp = xfp
        self.signType = signType
        self.address = address
        self.origin = origin
    }
}
