//
//  InMemorySecItemStoreTests.swift
//  zodlTests
//
//  Smoke tests for the in-memory SecItem double itself: store routing by the DP key, duplicate
//  detection, wildcard matching, and injected ACL-denial errors firing only on data reads.
//

import Testing
import Foundation
import Security
@testable import zodl_internal

@Suite struct InMemorySecItemStoreTests {
    @Test func dataProtectionKeyRoutesToSeparateStore() {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "svc", data: Data([1]))

        var fileQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "svc",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any
        ]
        var result: CFTypeRef?
        #expect(fake.client.copyMatching(fileQuery as CFDictionary, &result) == errSecSuccess)
        #expect(result as? Data == Data([1]))

        fileQuery[kSecUseDataProtectionKeychain as String] = true
        result = nil
        #expect(fake.client.copyMatching(fileQuery as CFDictionary, &result) == errSecItemNotFound)
    }

    @Test func addDetectsDuplicatesPerStore() {
        let fake = InMemorySecItemStore()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "svc",
            kSecAttrAccount as String: "",
            kSecValueData as String: Data([7])
        ]
        var result: CFTypeRef?
        #expect(fake.client.add(attributes as CFDictionary, &result) == errSecSuccess)
        #expect(fake.client.add(attributes as CFDictionary, &result) == errSecDuplicateItem)

        var dpAttributes = attributes
        dpAttributes[kSecUseDataProtectionKeychain as String] = true
        #expect(fake.client.add(dpAttributes as CFDictionary, &result) == errSecSuccess)
    }

    @Test func queriesWithoutAccountMatchAnyAccount() {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "svc", account: "acc-1", data: Data([3]))

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "svc",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any
        ]
        var result: CFTypeRef?
        #expect(fake.client.copyMatching(query as CFDictionary, &result) == errSecSuccess)
        #expect(result as? Data == Data([3]))
    }

    @Test func injectedReadErrorFiresOnDataReadsOnly() {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "svc", data: Data([9]))
        fake.injectFileReadError(service: "svc", status: errSecAuthFailed)

        let scan: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue as Any
        ]
        var result: CFTypeRef?
        #expect(fake.client.copyMatching(scan as CFDictionary, &result) == errSecSuccess)

        let read: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "svc",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any
        ]
        result = nil
        #expect(fake.client.copyMatching(read as CFDictionary, &result) == errSecAuthFailed)
        #expect(fake.dataReadCount(service: "svc", dataProtection: false) == 0)
    }

    @Test func deleteMissingItemReturnsNotFound() {
        let fake = InMemorySecItemStore()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "absent"
        ]
        #expect(fake.client.delete(query as CFDictionary) == errSecItemNotFound)
    }
}
