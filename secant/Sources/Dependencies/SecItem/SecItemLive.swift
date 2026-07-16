//
//  SecItemLive.swift
//  Zashi
//
//  Created by Lukáš Korba on 15.11.2022.
//

import Foundation
import Security

extension SecItemClient {
    static let live = SecItemClient(
        copyMatching: { query, result in
            SecItemCopyMatching(query, &result)
        },
        add: { attributes, result in
            SecItemAdd(attributes, &result)
        },
        update: { query, attributesToUpdate in
            SecItemUpdate(query, attributesToUpdate)
        },
        delete: { query in
            SecItemDelete(query)
        },
        fileKeychainItems: { result in
            #if os(macOS)
            // An UNFLAGGED SecItemCopyMatching consults BOTH keychain implementations on macOS.
            // Only file-keychain items are backed by a SecKeychainItemRef, so the ref is the
            // discriminator: keep exactly the results that carry one.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: kCFBooleanTrue as Any,
                kSecReturnRef as String: kCFBooleanTrue as Any
            ]
            var raw: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &raw)
            guard status == errSecSuccess else { return status }
            guard let items = raw as? [[String: Any]] else { return errSecDecode }
            let fileItems = items.filter { attributes in
                guard let ref = attributes[kSecValueRef as String] else { return false }
                return LegacyFileKeychain.isKeychainItemRef(ref as CFTypeRef)
            }
            guard !fileItems.isEmpty else { return errSecItemNotFound }
            result = fileItems as CFTypeRef
            return errSecSuccess
            #else
            return errSecUnimplemented
            #endif
        },
        fileKeychainReadData: { ref, result in
            #if os(macOS)
            // kSecMatchItemList (an array of SecKeychainItemRef) pins the read to exactly this
            // file-keychain item — the one relocation step a login-keychain ACL can gate.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecMatchItemList as String: [ref] as CFArray,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: kCFBooleanTrue as Any
            ]
            return SecItemCopyMatching(query as CFDictionary, &result)
            #else
            return errSecUnimplemented
            #endif
        },
        fileKeychainDeleteItem: { ref in
            #if os(macOS)
            LegacyFileKeychain.deleteItem(ref)
            #else
            errSecUnimplemented
            #endif
        }
    )
}

#if os(macOS)
/// The deliberately-contained legacy-keychain surface (expect deprecation warnings here — they
/// are the point). `SecKeychainItem*` is deprecated, but it is the only remaining public way to
/// (a) tell a file-keychain item from a Data Protection one — only file items are
/// `SecKeychainItemRef`-backed, and the macOS 26 SDK removed `SecKeychainCopySearchList` /
/// `SecKeychainCopyDefault`, so `kSecMatchSearchList` scoping is no longer constructible — and
/// (b) delete exactly ONE file item: `SecItemDelete` without `kSecUseDataProtectionKeychain`
/// deletes matching items from BOTH keychain implementations, which is precisely the MOB-1485
/// wallet-destroying regression. See docs/macos/KEYCHAIN_SE_HARDENING.md.
private enum LegacyFileKeychain {
    static func isKeychainItemRef(_ ref: CFTypeRef) -> Bool {
        CFGetTypeID(ref) == SecKeychainItemGetTypeID()
    }

    static func deleteItem(_ ref: CFTypeRef) -> OSStatus {
        guard isKeychainItemRef(ref) else { return errSecParam }
        return SecKeychainItemDelete(unsafeDowncast(ref, to: SecKeychainItem.self))
    }
}
#endif
