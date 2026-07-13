//
//  CardanoSignRequest.swift
//  
//
//  Created by LiYan on 5/22/23.
//

import Foundation

public struct CardanoSignRequest {
    public init(requestId: String, signData: String, utxos: [CardanoSignRequest.Utxo], certKeys: [CardanoSignRequest.CertKey], origin: String = "") {
        self.requestId = requestId
        self.signData = signData
        self.utxos = utxos
        self.certKeys = certKeys
        self.origin = origin
    }

    let requestId: String
    let signData: String
    let utxos: [Utxo]
    let certKeys: [CertKey]
    let origin: String

    public struct Utxo: Codable {
        public init(transactionHash: String, index: UInt32, amount: String, xfp: String, hdPath: String, address: String) {
            self.transactionHash = transactionHash
            self.index = index
            self.amount = amount
            self.xfp = xfp
            self.hdPath = hdPath
            self.address = address
        }

        let transactionHash: String
        let index: UInt32
        let amount: String
        let xfp: String
        let hdPath: String
        let address: String
    }

    public struct CertKey: Codable {
        public init(keyHash: String, xfp: String, keyPath: String) {
            self.keyHash = keyHash
            self.xfp = xfp
            self.keyPath = keyPath
        }

        let keyHash: String
        let xfp: String
        let keyPath: String
    }
}
