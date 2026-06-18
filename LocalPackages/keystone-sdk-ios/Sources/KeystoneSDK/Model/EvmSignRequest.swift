//
//  EvmSignRequest.swift
//  
//
//  Created by Renfeng Shi on 2023/7/17.
//

import Foundation

public struct EvmSignRequest {
    let requestId: String
    let signData: String
    let dataType: DataType
    let customChainIdentifier: Int32
    let account: Account

    let origin: String

    public enum DataType: Int32 {
        case arbitrary = 1
        case cosmosAmino = 2
        case cosmosDirect = 3
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

    public init(requestId: String, signData: String, dataType: DataType, customChainIdentifier: Int32, account: Account, origin: String = "") {
        self.requestId = requestId
        self.signData = signData
        self.dataType = dataType
        self.customChainIdentifier = customChainIdentifier
        self.account = account
        self.origin = origin
    }
}
