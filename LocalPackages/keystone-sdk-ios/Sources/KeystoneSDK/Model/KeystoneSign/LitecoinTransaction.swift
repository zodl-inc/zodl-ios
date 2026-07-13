//
//  LitecoinTransaction.swift
//  
//
//  Created by LiYan on 4/21/23.
//

import Foundation

public struct LitecoinTransaction: Codable {
    let fee: Int64
    let dustThreshold: Int32
    let memo: String
    let inputs: [Input]
    var outputs: [Output]

    public struct Input: Codable {
        let hash: String
        let index: Int32
        let utxo: Utxo
        let ownerKeyPath: String

        public init(hash: String, index: Int32, utxo: LitecoinTransaction.Input.Utxo, ownerKeyPath: String) {
            self.hash = hash
            self.index = index
            self.utxo = utxo
            self.ownerKeyPath = ownerKeyPath
        }

        public struct Utxo: Codable {
            let publicKey: String
            let script: String
            let value: Int64

            public init(publicKey: String, script: String = "", value: Int64) {
                self.publicKey = publicKey
                self.script = script
                self.value = value
            }
        }
    }

    public init(fee: Int64, dustThreshold: Int32 = 5460, memo: String = "", inputs: [LitecoinTransaction.Input], outputs: [Output]) {
        self.fee = fee
        self.dustThreshold = dustThreshold
        self.memo = memo
        self.inputs = inputs
        self.outputs = outputs
    }
}
