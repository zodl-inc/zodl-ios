//
//  InMemorySecItemStore.swift
//  zodlTests
//
//  Stateful in-memory keychain double for WalletStorage tests (the fake deferred in
//  WalletStoragePureTests). Two independent stores model macOS routing: queries carrying
//  kSecUseDataProtectionKeychain hit the "data protection" store, all others the "file"
//  (login-keychain) store. Item identity is (service, account), like the real keychain.
//  Injected read errors simulate a denied login-keychain ACL prompt: they fire only on
//  DATA reads (kSecReturnData) — attribute scans stay promptless, like the real thing.
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

    private let state = OSAllocatedUnfairLock(initialState: Stores())

    var client: SecItemClient {
        SecItemClient(
            copyMatching: { [self] query, result in copyMatching(query, &result) },
            add: { [self] attributes, result in add(attributes, &result) },
            update: { [self] query, attributes in update(query, attributes) },
            delete: { [self] query in delete(query) }
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

    // MARK: - SecItem semantics

    private static func fields(_ raw: CFDictionary) -> [String: Any]? {
        (raw as NSDictionary) as? [String: Any]
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
            let table = isDP ? stores.dataProtection : stores.file
            let matches = table
                .filter { key, _ in
                    (service == nil || key.service == service) && (account == nil || key.account == account)
                }
                .sorted { ($0.key.service, $0.key.account) < ($1.key.service, $1.key.account) }
            guard let first = matches.first else { return errSecItemNotFound }

            if wantsAttributes && matchAll {
                let attributes = matches.map { key, _ -> [String: Any] in
                    [
                        kSecAttrService as String: key.service,
                        kSecAttrAccount as String: key.account
                    ]
                }
                result = attributes as CFTypeRef
                return errSecSuccess
            }

            if wantsData {
                let errors = isDP ? stores.dataProtectionReadErrors : stores.fileReadErrors
                if let injected = errors[first.key] {
                    return injected
                }
                let counter = Self.readCounterKey(service: first.key.service, account: first.key.account, dataProtection: isDP)
                stores.dataReads[counter, default: 0] += 1
                result = first.value as CFTypeRef
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
            var table = isDP ? stores.dataProtection : stores.file
            let keys = table.keys.filter {
                (service == nil || $0.service == service) && (account == nil || $0.account == account)
            }
            guard !keys.isEmpty else { return errSecItemNotFound }
            for key in keys {
                table[key] = newData
            }
            if isDP {
                stores.dataProtection = table
            } else {
                stores.file = table
            }
            return errSecSuccess
        }
    }

    private func delete(_ rawQuery: CFDictionary) -> OSStatus {
        guard let query = Self.fields(rawQuery) else { return errSecParam }
        let isDP = query[kSecUseDataProtectionKeychain as String] as? Bool == true
        let service = query[kSecAttrService as String] as? String
        let account = query[kSecAttrAccount as String] as? String
        return state.withLock { stores in
            var table = isDP ? stores.dataProtection : stores.file
            let keys = table.keys.filter {
                (service == nil || $0.service == service) && (account == nil || $0.account == account)
            }
            guard !keys.isEmpty else { return errSecItemNotFound }
            for key in keys {
                table[key] = nil
            }
            if isDP {
                stores.dataProtection = table
            } else {
                stores.file = table
            }
            return errSecSuccess
        }
    }
}
