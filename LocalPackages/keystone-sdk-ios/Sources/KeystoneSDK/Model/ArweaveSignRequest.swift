//
//  ArweaveSignRequest.swift
//  
//
//  Created by LiYan on 4/27/23.
//

import Foundation

public struct ArweaveSignRequest {
    public init(masterFingerprint: String, requestId: String, signData: String, saltLen: ArweaveSignRequest.SaltLen, signType: ArweaveSignRequest.SignType, account: String = "", origin: String = "") {
        self.masterFingerprint = masterFingerprint
        self.requestId = requestId
        self.signData = signData
        self.saltLen = saltLen
        self.signType = signType
        self.account = account
        self.origin = origin
    }

    let masterFingerprint: String
    let requestId: String
    let signData: String
    let saltLen: SaltLen
    let signType: SignType
    let account: String
    let origin: String

    public enum SignType: Int32 {
        case transaction = 1
        case dataItem = 2
        case message = 3
    }

    public enum SaltLen: Int32 {
        case zero = 0
        case digest = 32
    }
}
