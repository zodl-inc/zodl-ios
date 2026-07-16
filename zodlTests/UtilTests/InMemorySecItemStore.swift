//
//  InMemorySecItemStore.swift
//  zodlTests
//
//  Stateful in-memory keychain double for WalletStorage tests (the fake deferred in
//  WalletStoragePureTests). Two independent stores model REAL macOS SecItem routing, verified
//  against a live Mac (MOB-1485 regression):
//    - queries carrying `kSecUseDataProtectionKeychain: true` hit ONLY the "data protection" store;
//    - queries WITHOUT the flag are NOT file-only — SecItemCopyMatching consults, and
//      SecItemDelete deletes from, BOTH implementations (file first, then data protection);
//    - only the dedicated `fileKeychain*` client primitives are scoped to the file (login
//      keychain) store, mirroring the live client's SecKeychainItemRef-based scoping.
//  File items surface an opaque ref token under `kSecValueRef` (data-protection items never do),
//  like the real unflagged scan. Item identity is (service, account), like the real keychain.
//  Injected read errors simulate a denied login-keychain ACL prompt: they fire only on DATA
//  reads (attribute scans stay promptless, like the real thing).
//

import Foundation
import Security
import os
@testable import zodl_internal

final class InMemorySecItemStore: Sendable {
    struct ItemKey: Hashable, Sendable {
        let service: String
        let account: String
    }

    private struct Stores: Sendable {
        var file: [ItemKey: Data] = [:]
        var dataProtection: [ItemKey: Data] = [:]
        var fileReadErrors: [ItemKey: OSStatus] = [:]
        var dataProtectionReadErrors: [ItemKey: OSStatus] = [:]
        var dataReads: [String: Int] = [:]
    }

    /// ASCII unit separator — cannot collide with the test suites' service/account strings.
    private static let refSeparator: Character = "\u{1F}"
    private static let refPrefix = "fileref\(refSeparator)"

    private let state = OSAllocatedUnfairLock(initialState: Stores())

    var client: SecItemClient {
        SecItemClient(
            copyMatching: { [self] query, result in copyMatching(query, &result) },
            add: { [self] attributes, result in add(attributes, &result) },
            update: { [self] query, attributes in update(query, attributes) },
            delete: { [self] query in delete(query) },
            fileKeychainItems: { [self] result in fileKeychainItems(&result) },
            fileKeychainReadData: { [self] ref, result in fileKeychainReadData(ref, &result) },
            fileKeychainDeleteItem: { [self] ref in fileKeychainDeleteItem(ref) }
        )
    }

    // MARK: - Seeding & inspection

    func seedFile(service: String, account: String = "", data: Data) {
        state.withLock { $0.file[ItemKey(service: service, account: account)] = data }
    }

    func seedDataProtection(service: String, account: String = "", data: Data) {
        state.withLock { $0.dataProtection[ItemKey(service: service, account: account)] = data }
    }

    func injectFileReadError(service: String, account: String = "", status: OSStatus) {
        state.withLock { $0.fileReadErrors[ItemKey(service: service, account: account)] = status }
    }

    func injectDataProtectionReadError(service: String, account: String = "", status: OSStatus) {
        state.withLock { $0.dataProtectionReadErrors[ItemKey(service: service, account: account)] = status }
    }

    func clearInjectedErrors() {
        state.withLock {
            $0.fileReadErrors = [:]
            $0.dataProtectionReadErrors = [:]
        }
    }

    func fileItems() -> [ItemKey: Data] {
        state.withLock { $0.file }
    }

    func dataProtectionItems() -> [ItemKey: Data] {
        state.withLock { $0.dataProtection }
    }

    func dataReadCount(service: String, account: String = "", dataProtection: Bool) -> Int {
        let key = Self.readCounterKey(service: service, account: account, dataProtection: dataProtection)
        return state.withLock { $0.dataReads[key] ?? 0 }
    }

    private static func readCounterKey(service: String, account: String, dataProtection: Bool) -> String {
        "\(dataProtection ? "dp" : "file"):\(service):\(account)"
    }

    // MARK: - File-item ref tokens (stand-ins for SecKeychainItemRef)

    private static func fileRef(_ key: ItemKey) -> CFTypeRef {
        "\(refPrefix)\(key.service)\(refSeparator)\(key.account)" as NSString
    }

    private static func parseFileRef(_ ref: CFTypeRef) -> ItemKey? {
        guard let token = ref as? String, token.hasPrefix(refPrefix) else { return nil }
        let body = token.dropFirst(refPrefix.count)
        guard let separator = body.firstIndex(of: refSeparator) else { return nil }
        return ItemKey(
            service: String(body[..<separator]),
            account: String(body[body.index(after: separator)...])
        )
    }

    // MARK: - SecItem semantics

    private static func fields(_ raw: CFDictionary) -> [String: Any]? {
        (raw as NSDictionary) as? [String: Any]
    }

    /// The stores a query operates on (`true` = data protection), in real macOS routing order:
    /// the flag scopes to the data-protection store alone; NO flag means BOTH stores, file first.
    private static func routedStores(isDataProtection: Bool) -> [Bool] {
        isDataProtection ? [true] : [false, true]
    }

    private func copyMatching(_ rawQuery: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus {
        guard let query = Self.fields(rawQuery) else { return errSecParam }
        let isDP = query[kSecUseDataProtectionKeychain as String] as? Bool == true
        let wantsData = query[kSecReturnData as String] as? Bool == true
        let wantsAttributes = query[kSecReturnAttributes as String] as? Bool == true
        let matchAll = (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
        let service = query[kSecAttrService as String] as? String
        let account = query[kSecAttrAccount as String] as? String

        // withLockUnchecked: the closure writes the caller's non-Sendable `inout CFTypeRef?`, which
        // the checked `withLock` (a `@Sendable` closure) rejects under Swift 6 strict concurrency.
        return state.withLockUnchecked { stores in
            var matches: [(key: ItemKey, data: Data, isDP: Bool)] = []
            for isDPStore in Self.routedStores(isDataProtection: isDP) {
                let items = isDPStore ? stores.dataProtection : stores.file
                matches += items
                    .filter { key, _ in
                        (service == nil || key.service == service) && (account == nil || key.account == account)
                    }
                    .sorted { ($0.key.service, $0.key.account) < ($1.key.service, $1.key.account) }
                    .map { (key: $0.key, data: $0.value, isDP: isDPStore) }
            }
            guard let first = matches.first else { return errSecItemNotFound }

            if wantsAttributes && matchAll {
                let attributes = matches.map { match -> [String: Any] in
                    var item: [String: Any] = [
                        kSecAttrService as String: match.key.service,
                        kSecAttrAccount as String: match.key.account
                    ]
                    // Only file-keychain items are SecKeychainItemRef-backed.
                    if !match.isDP {
                        item[kSecValueRef as String] = Self.fileRef(match.key)
                    }
                    return item
                }
                result = attributes as CFTypeRef
                return errSecSuccess
            }

            if wantsData {
                let errors = first.isDP ? stores.dataProtectionReadErrors : stores.fileReadErrors
                if let injected = errors[first.key] {
                    return injected
                }
                let counter = Self.readCounterKey(service: first.key.service, account: first.key.account, dataProtection: first.isDP)
                stores.dataReads[counter, default: 0] += 1
                result = first.data as CFTypeRef
            }
            return errSecSuccess
        }
    }

    private func add(_ rawAttributes: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus {
        guard
            let attributes = Self.fields(rawAttributes),
            let service = attributes[kSecAttrService as String] as? String,
            let data = attributes[kSecValueData as String] as? Data
        else { return errSecParam }
        let isDP = attributes[kSecUseDataProtectionKeychain as String] as? Bool == true
        let account = attributes[kSecAttrAccount as String] as? String ?? ""
        let key = ItemKey(service: service, account: account)
        return state.withLock { stores in
            // Adds are the one verb that never spans stores: flagged → data protection,
            // unflagged → the default file (login) keychain.
            if isDP {
                if stores.dataProtection[key] != nil { return errSecDuplicateItem }
                stores.dataProtection[key] = data
            } else {
                if stores.file[key] != nil { return errSecDuplicateItem }
                stores.file[key] = data
            }
            return errSecSuccess
        }
    }

    private func update(_ rawQuery: CFDictionary, _ rawAttributes: CFDictionary) -> OSStatus {
        guard
            let query = Self.fields(rawQuery),
            let attributes = Self.fields(rawAttributes),
            let newData = attributes[kSecValueData as String] as? Data
        else { return errSecParam }
        let isDP = query[kSecUseDataProtectionKeychain as String] as? Bool == true
        let service = query[kSecAttrService as String] as? String
        let account = query[kSecAttrAccount as String] as? String
        return state.withLock { stores in
            var updatedAny = false
            for isDPStore in Self.routedStores(isDataProtection: isDP) {
                var items = isDPStore ? stores.dataProtection : stores.file
                let keys = items.keys.filter {
                    (service == nil || $0.service == service) && (account == nil || $0.account == account)
                }
                for key in keys {
                    items[key] = newData
                    updatedAny = true
                }
                if isDPStore {
                    stores.dataProtection = items
                } else {
                    stores.file = items
                }
            }
            return updatedAny ? errSecSuccess : errSecItemNotFound
        }
    }

    private func delete(_ rawQuery: CFDictionary) -> OSStatus {
        guard let query = Self.fields(rawQuery) else { return errSecParam }
        let isDP = query[kSecUseDataProtectionKeychain as String] as? Bool == true
        let service = query[kSecAttrService as String] as? String
        let account = query[kSecAttrAccount as String] as? String
        return state.withLock { stores in
            var deletedAny = false
            for isDPStore in Self.routedStores(isDataProtection: isDP) {
                var items = isDPStore ? stores.dataProtection : stores.file
                let keys = items.keys.filter {
                    (service == nil || $0.service == service) && (account == nil || $0.account == account)
                }
                for key in keys {
                    items[key] = nil
                    deletedAny = true
                }
                if isDPStore {
                    stores.dataProtection = items
                } else {
                    stores.file = items
                }
            }
            return deletedAny ? errSecSuccess : errSecItemNotFound
        }
    }

    // MARK: - File-keychain-only primitives (mirroring the live SecKeychainItemRef scoping)

    private func fileKeychainItems(_ result: inout CFTypeRef?) -> OSStatus {
        state.withLockUnchecked { stores in
            guard !stores.file.isEmpty else { return errSecItemNotFound }
            let attributes = stores.file
                .sorted { ($0.key.service, $0.key.account) < ($1.key.service, $1.key.account) }
                .map { key, _ -> [String: Any] in
                    [
                        kSecAttrService as String: key.service,
                        kSecAttrAccount as String: key.account,
                        kSecValueRef as String: Self.fileRef(key)
                    ]
                }
            result = attributes as CFTypeRef
            return errSecSuccess
        }
    }

    private func fileKeychainReadData(_ ref: CFTypeRef, _ result: inout CFTypeRef?) -> OSStatus {
        guard let key = Self.parseFileRef(ref) else { return errSecParam }
        return state.withLockUnchecked { stores in
            guard let data = stores.file[key] else { return errSecItemNotFound }
            if let injected = stores.fileReadErrors[key] {
                return injected
            }
            let counter = Self.readCounterKey(service: key.service, account: key.account, dataProtection: false)
            stores.dataReads[counter, default: 0] += 1
            result = data as CFTypeRef
            return errSecSuccess
        }
    }

    private func fileKeychainDeleteItem(_ ref: CFTypeRef) -> OSStatus {
        guard let key = Self.parseFileRef(ref) else { return errSecParam }
        return state.withLock { stores in
            stores.file[key] = nil
            // SecKeychainItemDelete on an already-gone item "does nothing and returns
            // errSecSuccess" (SecKeychainItem.h) — model the same.
            return errSecSuccess
        }
    }
}
