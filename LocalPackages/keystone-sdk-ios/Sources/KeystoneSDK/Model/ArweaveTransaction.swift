//
//  ArweaveTransaction.swift
//  
//
//  Created by LiYan on 4/28/23.
//

import Foundation

public struct ArweaveTransaction : Equatable, Codable {
    public init(format: Int, id: String, lastTx: String, owner: String, tags: [ArweaveTransaction.Tag] = [], target: String, quantity: String, data: String = "", data_size: String = "0", data_root: String = "", reward: String, signature: String = "") {
        self.format = format
        self.id = id
        self.lastTx = lastTx
        self.owner = owner
        self.tags = tags
        self.target = target
        self.quantity = quantity
        self.data = data
        self.data_size = data_size
        self.data_root = data_root
        self.reward = reward
        self.signature = signature
    }

    public var format: Int
    public var id: String
    public var lastTx: String
    public var owner: String
    public var tags: [Tag]
    public var target: String
    public var quantity: String
    public var data: String
    public var data_size: String
    public var data_root: String
    public var reward: String
    public var signature: String

    public struct Tag: Equatable, Codable {
        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }

        public var name: String
        public var value: String
    }
}
