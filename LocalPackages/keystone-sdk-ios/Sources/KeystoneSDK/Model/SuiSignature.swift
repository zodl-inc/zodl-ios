//
//  SuiSignature.swift
//  
//
//  Created by Renfeng Shi on 2023/5/18.
//

import Foundation

public struct SuiSignature : Equatable, Codable {
    public var requestId: String
    public var signature: String
    public var publicKey: String
}
