//
//  SecItemClientTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 12.04.2022.
//

import Testing
import Foundation
import Security
import os
@testable import zodl_internal

extension WalletStorage.KeychainError {
    var debugValue: String {
        switch self {
        case .decoding: return "decoding"
        case .duplicate: return "duplicate"
        case .encoding: return "encoding"
        case .noDataFound: return "noDataFound"
        case .unknown: return "unknown"
        }
    }
}

@Suite struct SecItemClientTests {
    @Test func secItemAdd_KeychainErrorDuplicate() {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecDuplicateItem },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItemDuplicate)

        let error = #expect(throws: WalletStorage.KeychainError.self) {
            try walletStorage.setData(Data(), forKey: "")
        }

        #expect(
            error?.debugValue == WalletStorage.KeychainError.duplicate.debugValue,
            "SecItemClient: error must be .duplicate but it's \(String(describing: error))."
        )
    }

    @Test func secItemAdd_KeychainErrorUnknown() {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecCoreFoundationUnknown },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItemDuplicate)

        let error = #expect(throws: WalletStorage.KeychainError.self) {
            try walletStorage.setData(Data(), forKey: "")
        }

        #expect(
            error?.debugValue == WalletStorage.KeychainError.unknown(0).debugValue,
            "SecItemClient: error must be .unknown but it's \(String(describing: error))."
        )
    }

    @Test func secItemUpdate_KeychainErrorNoDataFound() {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecItemNotFound },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItemDuplicate)

        let error = #expect(throws: WalletStorage.KeychainError.self) {
            try walletStorage.updateData(Data(), forKey: "")
        }

        #expect(
            error?.debugValue == WalletStorage.KeychainError.noDataFound.debugValue,
            "SecItemClient: error must be .noDataFound but it's \(String(describing: error))."
        )
    }

    @Test func secItemUpdate_KeychainErrorUnknown() {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecCoreFoundationUnknown },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItemDuplicate)

        let error = #expect(throws: WalletStorage.KeychainError.self) {
            try walletStorage.updateData(Data(), forKey: "")
        }

        #expect(
            error?.debugValue == WalletStorage.KeychainError.unknown(0).debugValue,
            "SecItemClient: error must be .unknown but it's \(String(describing: error))."
        )
    }

    @Test func secItemDelete_Succeeded() {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { _ in noErr }
        )

        let walletStorage = WalletStorage(secItem: secItemDuplicate)

        #expect(throws: Never.self) {
            try walletStorage.deleteData(forKey: "")
        }
    }

    @Test func secItemDelete_Failed() {
        let secItemDuplicate = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecCoreFoundationUnknown }
        )

        let walletStorage = WalletStorage(secItem: secItemDuplicate)

        #expect(throws: (any Error).self) {
            try walletStorage.deleteData(forKey: "")
        }
    }

    // MARK: - Ironwood announcement flag

    @Test func importIronwoodAnnouncementFlag_DuplicateAddResultsInUpdate() throws {
        let updateWasCalled = OSAllocatedUnfairLock<Bool>(initialState: false)

        let secItem = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
            add: { _, _ in errSecDuplicateItem },
            update: { _, _ in
                updateWasCalled.withLock { $0 = true }
                return errSecSuccess
            },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItem)

        try walletStorage.importIronwoodAnnouncementFlag(true)

        #expect(updateWasCalled.withLock { $0 }, "A duplicate `add` must be followed by an `update` call.")
    }

    @Test func exportIronwoodAnnouncementFlag_ReturnsNilWhenItemNotFound() {
        let secItem = SecItemClient(
            copyMatching: { _, _ in errSecItemNotFound },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )

        let walletStorage = WalletStorage(secItem: secItem)

        #expect(walletStorage.exportIronwoodAnnouncementFlag() == nil)
    }

    @Test func exportIronwoodAnnouncementFlag_ReturnsTrueWhenStoredDataDecodesToTrue() throws {
        let storedData = try JSONEncoder().encode(true)

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

        #expect(walletStorage.exportIronwoodAnnouncementFlag() == true)
    }

    /// The Ironwood announcement is shown once per device and must survive a wallet reset (and an app
    /// reinstall), so `resetZashi` must never delete `zcashStoredIronwoodAnnouncementFlag`. This is
    /// deliberate, not an oversight -- see the comment on `WalletStorage.Constants.zcashStoredIronwoodAnnouncementFlag`.
    @Test func resetZashi_DoesNotDeleteIronwoodAnnouncementFlag_BecauseItMustSurviveAWalletReset() throws {
        let deletedServices = OSAllocatedUnfairLock<[String]>(initialState: [])

        let secItem = SecItemClient(
            copyMatching: { _, _ in errSecSuccess },
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
        #expect(!services.isEmpty, "Sanity check: resetZashi should have issued some deletes.")
        #expect(
            !services.contains(WalletStorage.Constants.zcashStoredIronwoodAnnouncementFlag),
            "resetZashi must not delete the Ironwood announcement flag -- it survives a wallet reset by design."
        )
    }
}
