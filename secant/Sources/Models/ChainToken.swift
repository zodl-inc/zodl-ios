//
//  ChainToken.swift
//  modules
//
//  Created by Lukáš Korba on 14.05.2025.
//

struct ChainToken: Equatable, Codable, Identifiable, Hashable {
    var id: String {
        "\(chain).\(token)"
    }
    
    let chain: String
    let token: String
    
    init(chain: String, token: String) {
        self.chain = chain
        self.token = token
    }
}
