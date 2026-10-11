//
//  WalletStorageLedgerBindingTests.swift
//  zodlTests
//
//  MOB-2020. Covers the Ledger binding import/export/delete trio and its `resetZashi()`
//  wiring (Dependencies/WalletStorage/WalletStorage.swift), using the `SecItemClient` mock
//  pattern established in `SecItemClientTests.swift`.
//

import Testing
import Foundation
import Security
import os
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite struct WalletStorageLedgerBindingTests {
    @Test func importLedgerBindingWritesUnderTheAccountKey() throws {
        let accountId = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))
        let expectedKey = WalletStorage.Constants.zcashStoredLedgerBinding(accountId: accountId)

        // The brief describes this as asserting `kSecAttrAccount`, but `WalletStorage.baseQuery`
        // puts the storage key (e.g. "zcashStoredLedgerBinding_<hex>") under `kSecAttrService`;
        // `kSecAttrAccount` is always the unused "" default here. Asserting `kSecAttrService` is
        // what actually verifies "writes under zcashStoredLedgerBinding_<hex>".
        let capturedService = OSAllocatedUnfairLock<String?>(initialState: nil)
        let capturedAccount = OSAllocatedUnfairLock<String?>(initialState: nil)

        let secItem = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { query, _ in
                if let attributes = query as? [String: Any] {
                    // Pull the Sendable `String?` values out of the non-Sendable `[String: Any]`
                    // query *before* crossing into the lock's closure -- capturing `attributes`
                    // itself there is what strict concurrency rejects.
                    let service = attributes[kSecAttrService as String] as? String
                    let account = attributes[kSecAttrAccount as String] as? String
                    capturedService.withLock { $0 = service }
                    capturedAccount.withLock { $0 = account }
                }
                return errSecSuccess
            },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItem)

        try walletStorage.importLedgerBinding(try ledgerAccountBinding(), accountId: accountId)

        #expect(capturedService.withLock { $0 } == expectedKey)
        #expect(capturedAccount.withLock { $0 } == "")
    }

    @Test func exportLedgerBindingDecodesBackAnEqualBinding() throws {
        let binding = try ledgerAccountBinding()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let storedData = try encoder.encode(binding)

        let secItem = SecItemClient(
            copyMatching: { _, result in
                result = storedData as CFTypeRef
                return errSecSuccess
            },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItem)
        let accountId = AccountUUID(id: [UInt8](repeating: 0x02, count: 16))

        let exported = try walletStorage.exportLedgerBinding(accountId: accountId)

        #expect(exported == binding)
    }

    @Test func exportLedgerBindingThrowsUninitializedWhenItemNotFound() {
        let secItem = SecItemClient(
            copyMatching: { _, _ in errSecItemNotFound },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItem)
        let accountId = AccountUUID(id: [UInt8](repeating: 0x03, count: 16))

        let error = #expect(throws: WalletStorage.WalletStorageError.self) {
            try walletStorage.exportLedgerBinding(accountId: accountId)
        }

        guard case .uninitializedLedgerBinding = error else {
            Issue.record("Expected .uninitializedLedgerBinding, got \(String(describing: error))")
            return
        }
    }

    // MOB-2020: a stored value that no longer decodes -- garbage bytes, or a field that no
    // longer parses -- must read as no binding at all, same as a missing item, rather than
    // surfacing `KeychainError.decoding` to `SendConfirmationStore.ledgerSignRequest`.
    @Test func exportLedgerBindingThrowsUninitializedWhenStoredBytesAreNotABinding() {
        let storedData = Data("not a binding".utf8)
        let secItem = SecItemClient(
            copyMatching: { _, result in
                result = storedData as CFTypeRef
                return errSecSuccess
            },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItem)
        let accountId = AccountUUID(id: [UInt8](repeating: 0x09, count: 16))

        let error = #expect(throws: WalletStorage.WalletStorageError.self) {
            try walletStorage.exportLedgerBinding(accountId: accountId)
        }

        guard case .uninitializedLedgerBinding = error else {
            Issue.record("Expected .uninitializedLedgerBinding, got \(String(describing: error))")
            return
        }
    }

    // `Zip32AccountIndex.new`/`init(_:)` isn't reachable with an out-of-range value from Swift
    // (it requires the UInt range), so the bytes are hand-written JSON instead -- the same way a
    // future incompatible encoding could turn up in the keychain.
    @Test func exportLedgerBindingThrowsUninitializedWhenTheAccountIndexIsOutsideUInt32() {
        for index in ["4294967296", "-1"] {
            let json = """
            {"deviceIdentity":"tpk0-\(String(repeating: "a", count: 64))","zip32AccountIndex":{"index":\(index)}}
            """
            let storedData = Data(json.utf8)
            let secItem = SecItemClient(
                copyMatching: { _, result in
                    result = storedData as CFTypeRef
                    return errSecSuccess
                },
                add: { _, _ in errSecSuccess },
                update: { _, _ in errSecSuccess },
                delete: { _ in errSecSuccess }
            )

            let walletStorage = WalletStorage(secItem: secItem)
            let accountId = AccountUUID(id: [UInt8](repeating: 0x0a, count: 16))

            let error = #expect(throws: WalletStorage.WalletStorageError.self) {
                try walletStorage.exportLedgerBinding(accountId: accountId)
            }

            guard case .uninitializedLedgerBinding = error else {
                Issue.record("Expected .uninitializedLedgerBinding for index \(index), got \(String(describing: error))")
                return
            }
        }
    }

    @Test func importLedgerBindingThrowsAlreadyImportedOnDuplicate() throws {
        let secItem = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecDuplicateItem },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItem)
        let accountId = AccountUUID(id: [UInt8](repeating: 0x04, count: 16))

        let error = #expect(throws: WalletStorage.WalletStorageError.self) {
            try walletStorage.importLedgerBinding(try ledgerAccountBinding(), accountId: accountId)
        }

        guard case .alreadyImported = error else {
            Issue.record("Expected .alreadyImported, got \(String(describing: error))")
            return
        }
    }

    @Test func deleteLedgerBindingOfAMissingItemDoesNotThrow() {
        let secItem = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecItemNotFound }
        )

        let walletStorage = WalletStorage(secItem: secItem)
        let accountId = AccountUUID(id: [UInt8](repeating: 0x05, count: 16))

        #expect(throws: Never.self) {
            try walletStorage.deleteLedgerBinding(accountId: accountId)
        }
    }

    @Test func resetZashiDeletesLedgerMetadataShieldingReminderAndEveryLedgerBindingItem() throws {
        let ledgerBindingServiceOne = WalletStorage.Constants.zcashStoredLedgerBinding(
            accountId: AccountUUID(id: [UInt8](repeating: 0x06, count: 16))
        )
        let ledgerBindingServiceTwo = WalletStorage.Constants.zcashStoredLedgerBinding(
            accountId: AccountUUID(id: [UInt8](repeating: 0x07, count: 16))
        )
        let votingHotkeyService = WalletStorage.Constants.zcashStoredVotingHotkey(
            accountId: AccountUUID(id: [UInt8](repeating: 0x08, count: 16))
        )

        // `keychainKeys(withPrefix:)` enumerates every generic-password item and filters
        // client-side, so a single fixed list drives both the voting-hotkey and the
        // ledger-binding prefix scans `resetZashi()` performs.
        // `[String: String]`, not `[String: Any]`: the array is captured directly by the
        // `@Sendable copyMatching` closure below, and `Any` isn't Sendable-checkable. The
        // bridge to `CFTypeRef` (NSArray of NSDictionary) is untyped either way, so
        // `WalletStorage`'s own `result as? [[String: Any]]` cast still succeeds.
        let allStoredItems: [[String: String]] = [
            [kSecAttrService as String: ledgerBindingServiceOne],
            [kSecAttrService as String: ledgerBindingServiceTwo],
            [kSecAttrService as String: votingHotkeyService],
            [kSecAttrService as String: "someUnrelatedService"]
        ]

        let deletedServices = OSAllocatedUnfairLock<[String]>(initialState: [])

        let secItem = SecItemClient(
            copyMatching: { query, result in
                guard let attributes = query as? [String: Any],
                      attributes[kSecReturnAttributes as String] != nil else {
                    return errSecItemNotFound
                }
                result = allStoredItems as CFTypeRef
                return errSecSuccess
            },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { query in
                if let attributes = query as? [String: Any], let service = attributes[kSecAttrService as String] as? String {
                    deletedServices.withLock { $0.append(service) }
                }
                return errSecSuccess
            }
        )

        let walletStorage = WalletStorage(secItem: secItem)

        try walletStorage.resetZashi()

        let services = deletedServices.withLock { $0 }
        #expect(services.contains("\(WalletStorage.Constants.zcashStoredUserMetadataEncryptionKeys)_ledger"))
        #expect(services.contains("\(WalletStorage.Constants.zcashStoredShieldingReminder)_ledger"))
        #expect(services.contains(ledgerBindingServiceOne))
        #expect(services.contains(ledgerBindingServiceTwo))
    }

    // MARK: - Fixtures

    /// A validated `LedgerDeviceIdentity`: the SDK requires the `tpk0-` prefix followed by 64
    /// lowercase hex digits, checked through the FFI. This literal (all `a`s) is a well-formed,
    /// non-secret placeholder -- not a real device identity.
    private func ledgerDeviceIdentity() throws -> LedgerDeviceIdentity {
        try LedgerDeviceIdentity(encoding: "tpk0-" + String(repeating: "a", count: 64))
    }

    private func ledgerAccountBinding() throws -> LedgerAccountBinding {
        LedgerAccountBinding(deviceIdentity: try ledgerDeviceIdentity(), zip32AccountIndex: Zip32AccountIndex(0))
    }
}
