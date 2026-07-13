//
//  UtxoBaseTransaction.swift
//
//
//  Created by LiYan on 4/21/23.
//

import Foundation

public struct UtxoBaseTransaction: Codable {
    let fee: Int64
    let dustThreshold: Int32
    let memo: String
    let inputs: [Input]
    var outputs: [Output]

    public init(fee: Int64, dustThreshold: Int32 = 546, memo: String = "", inputs: [Input], outputs: [Output]) {
        self.fee = fee
        self.dustThreshold = dustThreshold
        self.memo = memo
        self.inputs = inputs
        self.outputs = outputs
    }
}
