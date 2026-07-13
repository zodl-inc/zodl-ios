//
//  EthSignRequest.swift
//  
//
//  Created by LiYan on 3/29/23.
//

import Foundation

public struct EthSignRequest {
    let requestId: String
    let signData: String
    let dataType: DataType
    let chainId: Int32
    let path: String
    let xfp: String
    var address: String
    var origin: String

    public enum DataType: Int32 {
        case transaction = 1
        case typedData = 2
        case personalMessage = 3
        case typedTransaction = 4
    }

    public init(requestId: String, signData: String, dataType: DataType, chainId: Int32, path: String, xfp: String, address: String = "", origin: String = "") {
        self.requestId = requestId
        self.signData = signData
        self.dataType = dataType
        self.chainId = chainId
        self.path = path
        self.xfp = xfp
        self.address = address
        self.origin = origin
    }
}
