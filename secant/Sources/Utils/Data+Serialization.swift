//
//  Data+Serialization.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-02-19.
//

enum Serializer {
    static func stringToBytes(_ string: String) -> [UInt8] {
        return Array(string.utf8)
    }
    
    static func bytesToString(_ bytes: [UInt8]) -> String? {
        return String(bytes: bytes, encoding: .utf8)
    }
    
    static func intToBytes(_ value: Int) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}
