//
//  Contact.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-28-2024.
//

import Foundation

struct Contact: Equatable, Codable, Identifiable, Hashable {
    var id: String {
        "\(address)-\(chainId ?? "zcash")"
    }
    
    var address: String
    var name: String
    var lastUpdated: Date
    var chainId: String?

    init(
        address: String,
        name: String,
        lastUpdated: Date = Date(),
        chainId: String? = nil
    ) {
        self.address = address
        self.name = name
        self.lastUpdated = lastUpdated
        self.chainId = chainId
    }
}
