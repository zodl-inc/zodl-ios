//
//  NativeResult.swift
//  
//
//  Created by LiYan on 8/21/23.
//

import Foundation

public struct NativeResult<T: Codable>: Codable {
    public var result: T
}
