//
//  StoredWalletTests.swift
//  zodlTests
//
//  Batch 2 — persistence. Covers StoredWallet Codable round-trip (Models/StoredWallet.swift).
//

import Testing
import Foundation
@testable import zodl_internal
@testable @preconcurrency import ZODLSwiftWalletSDK

@Suite struct StoredWalletTests {
    @Test func placeholderCodableRoundTrip() throws {
        let original = StoredWallet.placeholder
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoredWallet.self, from: data)
        #expect(decoded == original)
    }

    @Test func codableRoundTripPreservesMutableFields() throws {
        var original = StoredWallet.placeholder
        original.birthday = Birthday(123_456)
        original.hasUserPassedPhraseBackupTest = true
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoredWallet.self, from: data)
        #expect(decoded == original)
        #expect(decoded.birthday == Birthday(123_456))
        #expect(decoded.hasUserPassedPhraseBackupTest)
    }
}
