//
//  SecItemClient.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.04.2022.
//

import Foundation
import Security

struct SecItemClient {
    var copyMatching: @Sendable (CFDictionary, inout CFTypeRef?) -> OSStatus = { _, _ in 0 }
    var add: @Sendable (CFDictionary, inout CFTypeRef?) -> OSStatus = { _, _ in 0 }
    var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus = { _, _ in 0 }
    var delete: @Sendable (CFDictionary) -> OSStatus = { _ in 0 }
}
