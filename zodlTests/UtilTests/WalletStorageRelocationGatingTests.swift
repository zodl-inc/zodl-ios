//
//  WalletStorageRelocationGatingTests.swift
//  zodlTests
//
//  MOB-1485: every public WalletStorage accessor passes the relocation gate first, so ANY first
//  keychain touch (including SplashView's areKeysPresent, which runs before all Root logic)
//  relocates legacy items — and a failed relocation surfaces as KeychainError.unknown instead of
//  ever reading as "no wallet". Also proves composition with the Secure-Enclave migration: a v1
//  plaintext wallet relocates as-is, then splits into SE ciphertext + metadata inside the DP
//  keychain, exactly as on a real un-migrated install.
//

import Testing
import Foundation
import Security
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct WalletStorageRelocationGatingTests {
    private func makeStorage(_ fake: InMemorySecItemStore, secureEnclave: SecureEnclaveClient? = nil) -> WalletStorage {
        var storage = WalletStorage(secItem: fake.client, secureEnclave: secureEnclave)
        storage.useDataProtectionKeychain = true
        return storage
    }

    private var reversingSecureEnclave: SecureEnclaveClient {
        SecureEnclaveClient(
            isAvailable: { true },
            encryptSeed: { plaintext in Data(plaintext.reversed()) },
            decryptSeed: { ciphertext, _ in Data(ciphertext.reversed()) },
            deleteKey: { }
        )
    }

    @Test func areKeysPresentTriggersRelocation() throws {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "zcashStoredWallet", data: Data([1]))
        let storage = makeStorage(fake)

        let present = try storage.areKeysPresent()

        #expect(present)
        #expect(fake.fileItems().isEmpty)
        #expect(fake.dataProtectionItems()[InMemorySecItemStore.ItemKey(service: "zcashStoredWallet", account: "")] == Data([1]))
    }

    @Test func throwingAccessorsThrowAfterDeniedRelocation() {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "zcashStoredWalletSeed", data: Data([1]))
        fake.injectFileReadError(service: "zcashStoredWalletSeed", status: errSecAuthFailed)
        let storage = makeStorage(fake)

        #expect(throws: WalletStorage.KeychainError.unknown(errSecAuthFailed)) {
            _ = try storage.areKeysPresent()
        }
        #expect(throws: WalletStorage.KeychainError.unknown(errSecAuthFailed)) {
            _ = try storage.exportWalletMetadata()
        }
        #expect(fake.fileItems().count == 1)
    }

    @Test func nonThrowingAccessorsDegradeAfterDeniedRelocation() {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "zcashStoredWalletSeed", data: Data([1]))
        fake.seedFile(service: "zcashStoredWalletBackupAcknowledged", data: Data([1]))
        fake.injectFileReadError(service: "zcashStoredWalletBackupAcknowledged", status: errSecAuthFailed)
        let storage = makeStorage(fake)

        #expect(storage.exportWalletBackupAcknowledged() == false)
        #expect(storage.exportTorSetupFlag() == nil)
        #expect(fake.fileItems().count == 2)
    }

    @Test func v1PlaintextWalletRelocatesThenMigratesToSecureEnclave() async throws {
        let fake = InMemorySecItemStore()

        var legacyStorage = WalletStorage(secItem: fake.client)
        legacyStorage.useDataProtectionKeychain = false
        try legacyStorage.importWallet(bip39: "quick brown fox", birthday: 2_700_000)
        #expect(fake.fileItems().count == 1)

        let storage = makeStorage(fake, secureEnclave: reversingSecureEnclave)
        let present = try storage.areKeysPresent()
        #expect(present == false)

        try await storage.migrateToSecureEnclaveIfNeeded()

        let dpItems = fake.dataProtectionItems()
        #expect(dpItems[InMemorySecItemStore.ItemKey(service: "zcashStoredWalletSeed", account: "")] != nil)
        #expect(dpItems[InMemorySecItemStore.ItemKey(service: "zcashStoredWalletMeta", account: "")] != nil)
        #expect(dpItems[InMemorySecItemStore.ItemKey(service: "zcashStoredWallet", account: "")] == nil)
        #expect(fake.fileItems().isEmpty)

        let wallet = try await storage.exportWallet()
        #expect(wallet.seedPhrase.value() == "quick brown fox")
    }
}
