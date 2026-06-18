//
//  ArweaveAccount.swift
//  
//
//  Created by LiYan on 4/27/23.
//

import Foundation

public struct ArweaveAccount : Equatable, Codable {
    public var masterFingerprint: String
    public var keyData: String
    public var device: String
}
