//
//  File.swift
//  
//
//  Created by Renfeng Shi on 2023/4/26.
//

import Foundation

public struct NearSignature : Equatable, Codable {
    public var requestId: String
    public var signature: [String]
}
