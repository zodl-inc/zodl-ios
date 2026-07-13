//
//  CosmosSignRequest.swift
//  
//
//  Created by Renfeng Shi on 2023/4/6.
//

import Foundation

public struct CosmosSignRequest {
    let requestId: String
    let signData: String
    let dataType: DataType
    let accounts: [Account]

    let origin: String

    public enum DataType: Int32 {
        case amino = 1
        case direct = 2
        case textual = 3
        case message = 4
    }
    
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

    public init(requestId: String, signData: String, dataType: DataType, accounts: [Account], origin: String = "") {
        self.requestId = requestId
        self.signData = signData
        self.dataType = dataType
        self.accounts = accounts
        self.origin = origin
    }
}
