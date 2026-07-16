//
//  KeychainRelocationTests.swift
//  zodlTests
//
//  MOB-1485: the once-per-process relocation of ZODL keychain items from the legacy file
//  (login) keychain into the Data Protection keychain. Crash-safe (verify-then-delete, file
//  bytes win on duplicates), self-healing (leftovers finish next run), sticky on failure
//  (a denied ACL prompt must surface as an error — never as "no wallet").
//

import Testing
import Foundation
import Security
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct KeychainRelocationTests {
    private func makeStorage(_ fake: InMemorySecItemStore, prefix: String = "") -> WalletStorage {
        var storage = WalletStorage(secItem: fake.client)
        storage.useDataProtectionKeychain = true
        storage.zcashStoredWalletPrefix = prefix
        return storage
    }

    @Test func movesAllOwnedItemsToDataProtectionStore() throws {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "zcashStoredWalletSeed", data: Data([1]))
        fake.seedFile(service: "zcashStoredWalletMeta", data: Data([2]))
        fake.seedFile(service: "zcashStorageVersion", data: Data([3]))
        fake.seedFile(service: "zcashStoredVotingHotkey_0101", data: Data([4]))
        fake.seedFile(service: "zcashStoredMetadataEncryptionKeys_zashi", data: Data([5]))
        let storage = makeStorage(fake)

        try storage.ensureRelocated()

        #expect(fake.fileItems().isEmpty)
        let moved = fake.dataProtectionItems()
        #expect(moved[InMemorySecItemStore.ItemKey(service: "zcashStoredWalletSeed", account: "")] == Data([1]))
        #expect(moved[InMemorySecItemStore.ItemKey(service: "zcashStoredWalletMeta", account: "")] == Data([2]))
        #expect(moved[InMemorySecItemStore.ItemKey(service: "zcashStorageVersion", account: "")] == Data([3]))
        #expect(moved[InMemorySecItemStore.ItemKey(service: "zcashStoredVotingHotkey_0101", account: "")] == Data([4]))
        #expect(moved[InMemorySecItemStore.ItemKey(service: "zcashStoredMetadataEncryptionKeys_zashi", account: "")] == Data([5]))
    }

    @Test func preservesAccountAttribute() throws {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "zcashStoredWalletSeed", account: "acc-1", data: Data([1]))
        let storage = makeStorage(fake)

        try storage.ensureRelocated()

        #expect(fake.dataProtectionItems()[InMemorySecItemStore.ItemKey(service: "zcashStoredWalletSeed", account: "acc-1")] == Data([1]))
    }

    @Test func leavesForeignItemsUntouchedAndUnread() throws {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "com.other.app.token", data: Data([9]))
        fake.seedFile(service: "zcashStoredWalletX", data: Data([8]))
        let storage = makeStorage(fake)

        try storage.ensureRelocated()

        #expect(fake.fileItems().count == 2)
        #expect(fake.dataProtectionItems().isEmpty)
        #expect(fake.dataReadCount(service: "com.other.app.token", dataProtection: false) == 0)
        #expect(fake.dataReadCount(service: "zcashStoredWalletX", dataProtection: false) == 0)
    }

    @Test func mainnetLeavesTestnetItemsAlone() throws {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "testnet_zcashStoredWalletSeed", data: Data([1]))
        let storage = makeStorage(fake, prefix: "")

        try storage.ensureRelocated()

        #expect(fake.fileItems().count == 1)
        #expect(fake.dataProtectionItems().isEmpty)
    }

    @Test func testnetMovesOnlyItsOwnItems() throws {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "testnet_zcashStoredWalletMeta", data: Data([1]))
        fake.seedFile(service: "zcashStoredWalletMeta", data: Data([2]))
        let storage = makeStorage(fake, prefix: "testnet_")

        try storage.ensureRelocated()

        #expect(fake.dataProtectionItems() == [InMemorySecItemStore.ItemKey(service: "testnet_zcashStoredWalletMeta", account: ""): Data([1])])
        #expect(fake.fileItems() == [InMemorySecItemStore.ItemKey(service: "zcashStoredWalletMeta", account: ""): Data([2])])
    }

    @Test func freshInstallIsNoOp() throws {
        let fake = InMemorySecItemStore()
        let storage = makeStorage(fake)

        try storage.ensureRelocated()

        #expect(fake.fileItems().isEmpty)
        #expect(fake.dataProtectionItems().isEmpty)
    }

    @Test func successIsMemoizedPerProcess() throws {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "zcashStoredWalletMeta", data: Data([2]))
        let storage = makeStorage(fake)

        try storage.ensureRelocated()
        fake.seedFile(service: "zcashStoredWalletSeed", data: Data([1]))
        try storage.ensureRelocated()

        #expect(fake.fileItems().count == 1)
    }

    @Test func deniedReadFailsStickyAndLeavesEverything() throws {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "zcashStorageVersion", data: Data([3]))
        fake.seedFile(service: "zcashStoredWalletSeed", data: Data([1]))
        fake.injectFileReadError(service: "zcashStorageVersion", status: errSecAuthFailed)
        let storage = makeStorage(fake)

        #expect(throws: WalletStorage.KeychainError.unknown(errSecAuthFailed)) {
            try storage.ensureRelocated()
        }
        #expect(fake.fileItems().count == 2)
        #expect(fake.dataProtectionItems().isEmpty)

        fake.clearInjectedErrors()
        #expect(throws: WalletStorage.KeychainError.unknown(errSecAuthFailed)) {
            try storage.ensureRelocated()
        }
        #expect(fake.fileItems().count == 2)
    }

    @Test func bestEffortGateDoesNotThrowOnFailure() {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "zcashStoredWalletSeed", data: Data([1]))
        fake.injectFileReadError(service: "zcashStoredWalletSeed", status: errSecAuthFailed)
        let storage = makeStorage(fake)

        storage.ensureRelocatedBestEffort()

        #expect(fake.fileItems().count == 1)
    }

    @Test func verifyFailureLeavesFileOriginal() throws {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "zcashStoredWalletSeed", data: Data([1]))
        fake.injectDataProtectionReadError(service: "zcashStoredWalletSeed", status: errSecIO)
        let storage = makeStorage(fake)

        #expect(throws: WalletStorage.KeychainError.unknown(errSecIO)) {
            try storage.ensureRelocated()
        }
        #expect(fake.fileItems()[InMemorySecItemStore.ItemKey(service: "zcashStoredWalletSeed", account: "")] == Data([1]))
    }

    @Test func duplicateFromCrashedRunResolvedFileBytesWin() throws {
        let fake = InMemorySecItemStore()
        fake.seedDataProtection(service: "zcashStoredWalletSeed", data: Data([9, 9]))
        fake.seedFile(service: "zcashStoredWalletSeed", data: Data([1]))
        let storage = makeStorage(fake)

        try storage.ensureRelocated()

        #expect(fake.dataProtectionItems()[InMemorySecItemStore.ItemKey(service: "zcashStoredWalletSeed", account: "")] == Data([1]))
        #expect(fake.fileItems().isEmpty)
    }

    /// THE shipped regression (caught on a real Mac via secd's log): on macOS, SecItem calls
    /// WITHOUT `kSecUseDataProtectionKeychain` operate on BOTH keychain implementations. The
    /// original engine scanned and deleted unscoped, so every launch re-discovered the app's own
    /// DP items as "legacy file leftovers" and the delete-the-original step destroyed the freshly
    /// written DP copy — the wallet vanished on every relaunch.
    @Test func relocatedWalletSurvivesRelaunches() throws {
        let fake = InMemorySecItemStore()
        fake.seedFile(service: "zcashStoredWalletSeed", data: Data([1]))
        let seedKey = InMemorySecItemStore.ItemKey(service: "zcashStoredWalletSeed", account: "")

        let firstLaunch = makeStorage(fake)
        try firstLaunch.ensureRelocated()
        #expect(fake.dataProtectionItems()[seedKey] == Data([1]))
        #expect(fake.fileItems().isEmpty)

        // Relaunch = fresh process = fresh once-per-process gate over the same keychain state.
        let secondLaunch = makeStorage(fake)
        try secondLaunch.ensureRelocated()
        #expect(fake.dataProtectionItems()[seedKey] == Data([1]))

        let thirdLaunch = makeStorage(fake)
        try thirdLaunch.ensureRelocated()
        #expect(fake.dataProtectionItems()[seedKey] == Data([1]))
    }

    /// A wallet living purely in the DP keychain (fresh install, or any launch after relocation)
    /// must be invisible to the legacy scan: no re-relocation, no reads, no deletes.
    @Test func scanIgnoresDataProtectionItems() throws {
        let fake = InMemorySecItemStore()
        fake.seedDataProtection(service: "zcashStoredWalletSeed", data: Data([7]))
        let storage = makeStorage(fake)

        try storage.ensureRelocated()

        #expect(fake.dataProtectionItems()[InMemorySecItemStore.ItemKey(service: "zcashStoredWalletSeed", account: "")] == Data([7]))
        #expect(fake.dataReadCount(service: "zcashStoredWalletSeed", dataProtection: true) == 0)
    }
}
