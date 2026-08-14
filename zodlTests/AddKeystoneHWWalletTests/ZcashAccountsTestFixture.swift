//
//  ZcashAccountsTestFixture.swift
//  zodlTests
//
//  Shared ZcashAccounts fixture for the AddKeystoneHWWallet suites.
//

import Foundation
@preconcurrency import KeystoneSDK

extension ZcashAccounts {
    /// ZcashAccounts/ZcashUnifiedFullViewingKey have internal memberwise inits (inaccessible from
    /// this test module), so decode from JSON using their Codable conformance instead.
    static func testFixture() -> ZcashAccounts {
        let json = Data("""
            {
                "seedFingerprint": "\(String(repeating: "aa", count: 32))",
                "accounts": [{"ufvk": "utest1abc", "index": 0, "name": "Keystone"}]
            }
            """.utf8)
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ZcashAccounts.self, from: json)
    }
}
