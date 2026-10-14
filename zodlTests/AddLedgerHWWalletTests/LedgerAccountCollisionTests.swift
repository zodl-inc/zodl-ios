//
//  LedgerAccountCollisionTests.swift
//  zodlTests
//
//  Covers LedgerAccountCollision's recognition of librustzcash's "account already in the wallet"
//  import refusal and its lookup of the existing account the Rust error text names
//  (Features/AddLedgerHWWallet/LedgerAccountCollision.swift).
//

import Testing
import Foundation
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite struct LedgerAccountCollisionTests {

    // MARK: - Recognizing the collision and finding its account

    @Test func recognisesTheRustCollisionMessageAndItsAccount() {
        let existing = Self.walletAccount(idByte: 0x0f)
        let other = Self.walletAccount(idByte: 0x01)
        let error = ZcashError.rustImportAccountUfvk(
            """
            Error while initializing accounts: An account corresponding to the data provided already \
            exists in the wallet with UUID AccountUuid(0f0f0f0f-0f0f-0f0f-0f0f-0f0f0f0f0f0f).
            """
        )

        #expect(LedgerAccountCollision.isCollision(error))
        #expect(LedgerAccountCollision.collidingAccount(in: error, among: [other, existing]) == existing)
    }

    @Test func aCollisionNamingNoKnownAccountStillCountsAsACollision() {
        let unrelated = Self.walletAccount(idByte: 0x02)
        let error = ZcashError.rustImportAccountUfvk(
            """
            Error while initializing accounts: An account corresponding to the data provided already \
            exists in the wallet with UUID AccountUuid(67e55044-10b1-426f-9247-bb680e5fe0c8).
            """
        )

        #expect(LedgerAccountCollision.isCollision(error))
        #expect(LedgerAccountCollision.collidingAccount(in: error, among: [unrelated]) == nil)
    }

    @Test func otherImportFailuresAreNotCollisions() {
        let anotherAccount = Self.walletAccount(idByte: 0x01)

        let unrelatedRustFailure = ZcashError.rustImportAccountUfvk("Error while initializing accounts: could not decode UFVK")
        #expect(!LedgerAccountCollision.isCollision(unrelatedRustFailure))
        #expect(LedgerAccountCollision.collidingAccount(in: unrelatedRustFailure, among: [anotherAccount]) == nil)

        let nonImportZcashError = ZcashError.ledgerDeviceMismatch
        #expect(!LedgerAccountCollision.isCollision(nonImportZcashError))
        #expect(LedgerAccountCollision.collidingAccount(in: nonImportZcashError, among: [anotherAccount]) == nil)

        let foreignError = URLError(.notConnectedToInternet)
        #expect(!LedgerAccountCollision.isCollision(foreignError))
        #expect(LedgerAccountCollision.collidingAccount(in: foreignError, among: [anotherAccount]) == nil)
    }

    // MARK: - existingAccount(matching:among:)

    @Test func existingAccountMatchesOnlyAnIdenticalViewingKey() {
        let matchingUFVK = "uview1ledgerpairingfixture"
        let existing = Self.walletAccount(idByte: 0x0f, ufvk: matchingUFVK)
        let differentUFVK = Self.walletAccount(idByte: 0x01, ufvk: "uview1anotherpairingfixture")
        let noUFVK = Self.walletAccount(idByte: 0x02)

        // Finds the account with the same UFVK string, among others.
        #expect(LedgerAccountCollision.existingAccount(matching: matchingUFVK, among: [differentUFVK, noUFVK, existing]) == existing)
        // A different UFVK string never matches, even against the same wallet accounts.
        #expect(LedgerAccountCollision.existingAccount(matching: "uview1notpresentfixture", among: [differentUFVK, noUFVK, existing]) == nil)
        // An account with no UFVK never matches, no matter what string is asked for.
        #expect(LedgerAccountCollision.existingAccount(matching: matchingUFVK, among: [noUFVK]) == nil)
    }

    // MARK: - Helpers

    /// Mirrors AddLedgerHWWalletTests' own private fixture. `ufvk` defaults to `nil`, matching an
    /// account that was never asked to carry a viewing key (the collidingAccount tests above key
    /// only off `id`).
    private static func walletAccount(idByte: UInt8, ufvk: String? = nil) -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
            name: "Ledger",
            keySource: Account.ledgerKeySource,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: ufvk.map { UnifiedFullViewingKey(validatedEncoding: $0) },
            uivk: nil
        ))
    }
}
