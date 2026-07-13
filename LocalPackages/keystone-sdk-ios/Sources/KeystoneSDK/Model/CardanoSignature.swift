//
//  CardanoSignature.swift
//  
//
//  Created by LiYan on 5/22/23.
//

import Foundation

public struct CardanoSignature: Codable, Equatable {
    public var requestId: String
    public var witnessSet: String
}
