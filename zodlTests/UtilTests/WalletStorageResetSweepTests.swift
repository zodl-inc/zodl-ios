//
//  WalletStorageResetSweepTests.swift
//  zodlTests
//
//  MOB-1485: resetZashi wipes BOTH keychains on macOS — the DP keychain (its normal deletes) and
//  any ZODL leftovers in the legacy file keychain — and it must keep working even when relocation
//  failed (it is the escape hatch, so it is deliberately not gated).
//

import Testing
import Foundation
import Security
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct WalletStorageResetSweepTests {
    private func makeStorage(_ fake: InMemorySecItemStore) -> WalletStorage {
        var storage = WalletStorage(
            secItem: fake.client,
            secureEnclave: SecureEnclaveClient(
                isAvailable: { true },
                encryptSeed: { plaintext in Data(plaintext.reversed()) },
                decryptSeed: { ciphertext, _ in Data(ciphertext.reversed()) },
                deleteKey: { }
            )
        )
        storage.useDataProtectionKeychain = true
        return storage
    }

    @Test func resetWipesBothKeychainsAndSparesForeignItems() throws {
        let fake = InMemorySecItemStore()
        fake.seedDataProtection(service: "zcashStoredWalletSeed", data: Data([1]))
        fake.seedDataProtection(service: "zcashStoredWalletMeta", data: Data([2]))
        fake.seedDataProtection(service: "zcashStoredVotingHotkey_0101", data: Data([3]))
        fake.seedFile(service: "zcashStoredWallet", data: Data([4]))
        fake.seedFile(service: "zcashStoredTorSetupFlag", data: Data([5]))
        fake.seedFile(service: "com.other.app.token", data: Data([6]))
        let storage = makeStorage(fake)

        try storage.resetZashi()

        #expect(fake.dataProtectionItems().isEmpty)
        #expect(fake.fileItems() == [InMemorySecItemStore.ItemKey(service: "com.other.app.token", account: ""): Data([6])])
    }

    @Test func resetWorksAfterFailedRelocation() throws {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "zcashStoredWalletSeed", data: Data([1]))
        fake.injectFileReadError(service: "zcashStoredWalletSeed", status: errSecAuthFailed)
        let storage = makeStorage(fake)

        #expect(throws: WalletStorage.KeychainError.unknown(errSecAuthFailed)) {
            _ = try storage.areKeysPresent()
        }

        try storage.resetZashi()

        #expect(fake.fileItems().isEmpty)
    }

    @Test func resetAfterFailedRelocationClearsStickyGate() throws {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "zcashStoredWalletSeed", data: Data([1]))
        fake.injectFileReadError(service: "zcashStoredWalletSeed", status: errSecAuthFailed)
        let storage = makeStorage(fake)

        #expect(throws: WalletStorage.KeychainError.unknown(errSecAuthFailed)) {
            _ = try storage.areKeysPresent()
        }

        try storage.resetZashi()

        // The sweep emptied the file keychain, so the failed gate is stale — a successful reset
        // re-derives it and the storage works again as a fresh, walletless install. Without this,
        // the post-reset verification read in Root's resetZashiFinishProcessing would rethrow the
        // stale failure and mis-report a successful wipe as "corrupted data".
        #expect(try storage.areKeysPresent() == false)
        try storage.importWalletBackupAcknowledged(true)
        #expect(storage.exportWalletBackupAcknowledged() == true)
    }
}
