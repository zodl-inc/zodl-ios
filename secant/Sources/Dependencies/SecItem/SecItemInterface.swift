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

    // File-keychain-ONLY primitives (MOB-1485). On macOS, SecItem calls WITHOUT
    // `kSecUseDataProtectionKeychain` are NOT scoped to the legacy file keychain — copy/delete
    // operate on BOTH keychain implementations. Anything that must touch only the file (login)
    // keychain — the relocation scan, its ACL-gated read, and the delete of relocated originals —
    // goes through these, which the live client scopes via SecKeychainItemRef. Never called on
    // iOS (there is no file keychain).

    /// Attribute scan of ONLY the file keychain's generic passwords. On success, the result is an
    /// array of dictionaries carrying `kSecAttrService`, `kSecAttrAccount`, and `kSecValueRef`
    /// (the item's `SecKeychainItemRef`). `errSecItemNotFound` when the file keychain has none.
    var fileKeychainItems: @Sendable (inout CFTypeRef?) -> OSStatus = { _ in 0 }
    /// Data of exactly one file-keychain item, identified by the `kSecValueRef` handle the scan
    /// returned. The one relocation step a login-keychain ACL can gate (may prompt).
    var fileKeychainReadData: @Sendable (CFTypeRef, inout CFTypeRef?) -> OSStatus = { _, _ in 0 }
    /// Deletes exactly one file-keychain item by its `kSecValueRef` handle. Succeeds if the item
    /// is already gone.
    var fileKeychainDeleteItem: @Sendable (CFTypeRef) -> OSStatus = { _ in 0 }
}
