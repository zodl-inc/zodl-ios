//
//  SuiSignRequest.swift
//  
//
//  Created by Renfeng Shi on 2023/5/18.
//

import Foundation

public struct SuiSignRequest {
    let requestId: String
    let intentMessage: String
    let accounts: [Account]
    var origin: String

    public struct Account: Encodable {
        let path: String
        let xfp: String
        let address: String

        public init(path: String, xfp: String, address: String = "") {
            self.path = path
            self.xfp = xfp
            self.address = address
        }
    }

    public init(requestId: String, intentMessage: String, accounts: [Account], origin: String = "") {
        self.requestId = requestId
        self.intentMessage = intentMessage
        self.accounts = accounts
        self.origin = origin
    }
}
