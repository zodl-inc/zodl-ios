//
//  AddLedgerHWWalletTests.swift
//  zodlTests
//
//  Covers AddLedgerHWWallet's Bluetooth scan/connect/pair flow, the unlock guard, importing
//  with the Ledger key source and storing the binding, imported-account selection and
//  disconnecting on every exit path (Features/AddLedgerHWWallet/AddLedgerHWWalletStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// `AddLedgerHWWallet.State` carries `@Shared(.inMemory(...))` process-global storage, same as
// AddKeystoneHWWalletTests — `.serialized` keeps this suite's own tests from racing each other.
@Suite(.serialized) struct AddLedgerHWWalletTests {
    // MARK: - startScanning

    @MainActor @Test func startScanningForwardsDeviceBatches() async {
        let deviceA = LedgerBluetoothDevice(id: UUID(), name: "Nano X A", model: .nanoX, rssi: -40)
        let deviceB = LedgerBluetoothDevice(id: UUID(), name: "Nano X B", model: .nanoX, rssi: -55)
        let store = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.ledgerClient.scanDevices = {
                AsyncThrowingStream { continuation in
                    continuation.yield([deviceA])
                    continuation.yield([deviceA, deviceB])
                    continuation.finish()
                }
            }
        }

        await store.send(.startScanning) {
            $0.isScanning = true
            $0.scanError = nil
            $0.devices = []
        }
        await store.receive(\.devicesUpdated) {
            $0.devices = [deviceA]
        }
        await store.receive(\.devicesUpdated) {
            $0.devices = [deviceA, deviceB]
        }
        await store.finish()
    }

    @MainActor @Test func scanFailureMapsToTheLedgerErrorText() async {
        let store = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.ledgerClient.scanDevices = {
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ZcashError.ledgerBluetoothPoweredOff)
                }
            }
        }

        await store.send(.startScanning) {
            $0.isScanning = true
            $0.scanError = nil
            $0.devices = []
        }
        await store.receive(.scanFailed(String(localizable: .ledgerErrorBluetoothOff))) {
            $0.isScanning = false
            $0.scanError = String(localizable: .ledgerErrorBluetoothOff)
        }
        await store.finish()
    }

    // MARK: - deviceTapped

    @MainActor @Test func deviceTappedConnectsAndReportsSuccess() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        let connectedDevice = LockIsolated<LedgerBluetoothDevice?>(nil)
        let store = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.ledgerClient.connect = { device in connectedDevice.setValue(device) }
        }

        await store.send(.deviceTapped(device)) {
            $0.selectedDevice = device
            $0.isConnecting = true
            $0.scanError = nil
        }
        await store.receive(\.deviceConnected) {
            $0.isConnecting = false
        }
        await store.finish()

        #expect(connectedDevice.value == device)
    }

    @MainActor @Test func deviceTappedReportsAConnectionFailure() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        let store = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.ledgerClient.connect = { _ in throw ZcashError.ledgerBluetoothConnectionFailed(nil) }
        }

        await store.send(.deviceTapped(device)) {
            $0.selectedDevice = device
            $0.isConnecting = true
            $0.scanError = nil
        }
        await store.receive(.deviceConnectionFailed(String(localizable: .ledgerErrorConnectionLost))) {
            $0.isConnecting = false
            $0.scanError = String(localizable: .ledgerErrorConnectionLost)
        }
        await store.finish()
    }

    // MARK: - startPairing

    @MainActor @Test func startPairingStoresThePairingAndDerivedAddress() async throws {
        let fixture = try Self.makePairingFixture()
        let fixedAddress = UnifiedAddress(validatedEncoding: "u1ledgerpairingfixture", networkType: .mainnet)

        let store = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.ledgerClient.pairAccount = { zip32AccountIndex in
                #expect(zip32AccountIndex == Zip32AccountIndex(0))
                return fixture
            }
        }

        await store.send(.startPairing) {
            $0.isPairing = true
            $0.scanError = nil
        }
        await store.receive(.pairingSucceeded(fixture)) {
            $0.isPairing = false
            $0.pairing = fixture
        }
        await store.finish()

        // `pairedAddress` resolves its own `@Dependency(\.derivationTool)` inline (same technique
        // as AddKeystoneHWWallet.State.keystoneAddress), so exercising it needs its own
        // withDependencies scope — matching AddKeystoneHWWalletCoordFlowTests'
        // sendSupportMailFinishedClearsSupportData, which reads WalletStorage the same way.
        let derivedAddress = withDependencies {
            $0.derivationTool.deriveUnifiedAddressFrom = { ufvk, _ in
                #expect(ufvk == "utest1fixture")
                return fixedAddress
            }
        } operation: {
            store.state.pairedAddress
        }
        #expect(derivedAddress == fixedAddress.stringEncoded)
    }

    @MainActor @Test func pairingFailureFlagsConnectionLossOnlyForTransportErrors() async {
        let transportStore = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.ledgerClient.pairAccount = { _ in throw ZcashError.ledgerTimeout }
        }
        await transportStore.send(.startPairing) {
            $0.isPairing = true
            $0.scanError = nil
        }
        await transportStore.receive(.pairingFailed(message: String(localizable: .ledgerErrorConnectionLost), connectionLost: true)) {
            $0.isPairing = false
            $0.scanError = String(localizable: .ledgerErrorConnectionLost)
        }
        await transportStore.finish()

        let refusalStore = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.ledgerClient.pairAccount = { _ in throw ZcashError.ledgerUserRejected }
        }
        await refusalStore.send(.startPairing) {
            $0.isPairing = true
            $0.scanError = nil
        }
        await refusalStore.receive(.pairingFailed(message: String(localizable: .ledgerErrorUserRejected), connectionLost: false)) {
            $0.isPairing = false
            $0.scanError = String(localizable: .ledgerErrorUserRejected)
        }
        await refusalStore.finish()
    }

    // MARK: - unlockTapped

    @MainActor @Test func unlockTappedImportsWithTheLedgerKeySourceAndNoDerivationAndStoresTheBinding() async throws {
        let fixture = try Self.makePairingFixture()
        var state = AddLedgerHWWallet.State()
        state.pairing = fixture
        let uuid = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))

        struct CapturedImportArgs: Equatable {
            let ufvk: String
            let seedFingerprint: [UInt8]?
            let zip32AccountIndex: Zip32AccountIndex?
            let purpose: AccountPurpose
            let name: String
            let keySource: String?
            let birthday: BlockHeight?
        }
        let capturedArgs = LockIsolated<CapturedImportArgs?>(nil)
        let storedBinding = LockIsolated<(binding: LedgerAccountBinding, accountId: AccountUUID)?>(nil)

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer = .mocked(
                importAccount: { ufvk, seedFingerprint, zip32AccountIndex, purpose, name, keySource, birthday in
                    capturedArgs.setValue(
                        CapturedImportArgs(
                            ufvk: ufvk,
                            seedFingerprint: seedFingerprint,
                            zip32AccountIndex: zip32AccountIndex,
                            purpose: purpose,
                            name: name,
                            keySource: keySource,
                            birthday: birthday
                        )
                    )
                    return uuid
                },
                walletAccounts: { [] }
            )
            $0.walletStorage = .noOp
            $0.walletStorage.importLedgerBinding = { binding, accountId in
                storedBinding.setValue((binding, accountId))
            }
            // The chain this test drives ends in accountImportSucceeded, which disconnects —
            // LedgerClient has no test/preview value (Phase 0 only registered `liveValue`), so
            // that call needs an explicit override or it trips "has no test implementation".
            $0.ledgerClient = .noOp
        }
        store.exhaustivity = .off

        await store.send(.unlockTapped(3_000_000))
        await store.receive(\.accountImported)
        await store.receive(\.loadedWalletAccounts)
        await store.receive(\.accountImportSucceeded)
        await store.finish()

        let args = try #require(capturedArgs.value)
        #expect(args.ufvk == "utest1fixture")
        #expect(args.seedFingerprint == nil)
        #expect(args.zip32AccountIndex == nil)
        #expect(args.purpose == .spending)
        #expect(args.name == String(localizable: .accountsLedger))
        #expect(args.keySource == Account.ledgerKeySource)
        #expect(args.birthday == 3_000_000)

        let stored = try #require(storedBinding.value)
        #expect(stored.binding == fixture.binding)
        #expect(stored.accountId == uuid)
    }

    @MainActor @Test func unlockTappedIgnoresRetapsWhileImporting() async throws {
        let fixture = try Self.makePairingFixture()
        var state = AddLedgerHWWallet.State()
        state.pairing = fixture
        let importCount = LockIsolated(0)
        // The mock parks on this instead of a real-time sleep, and the test releases it only
        // after the re-tap below has already been sent -- so "while import is in flight" holds
        // by construction, not by racing a timer against however busy the main actor is.
        let (releaseImport, releaseImportContinuation) = AsyncStream<Void>.makeStream()
        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer = .mocked(
                importAccount: { _, _, _, _, _, _, _ in
                    importCount.withValue { $0 += 1 }
                    for await _ in releaseImport { break }
                    return AccountUUID(id: [UInt8](repeating: 0x01, count: 16))
                },
                walletAccounts: { [] }
            )
            $0.walletStorage = .noOp
            // See the comment in unlockTappedImportsWithTheLedgerKeySourceAndNoDerivationAndStoresTheBinding.
            $0.ledgerClient = .noOp
        }
        store.exhaustivity = .off

        await store.send(.unlockTapped(nil)) { $0.isImportingAccount = true }
        await store.send(.unlockTapped(nil))
        releaseImportContinuation.yield(())
        releaseImportContinuation.finish()
        await store.receive(\.accountImportSucceeded, timeout: .seconds(2))
        await store.finish()

        #expect(importCount.value == 1)
    }

    @MainActor @Test func bindingStoreFailureReportsAnImportFailure() async throws {
        let fixture = try Self.makePairingFixture()
        var state = AddLedgerHWWallet.State()
        state.pairing = fixture
        let uuid = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer = .mocked(importAccount: { _, _, _, _, _, _, _ in uuid })
            $0.walletStorage = .noOp
            $0.walletStorage.importLedgerBinding = { _, _ in
                throw WalletStorage.WalletStorageError.alreadyImported
            }
        }

        await store.send(.unlockTapped(nil)) { $0.isImportingAccount = true }
        await store.receive(\.accountImportFailed) {
            $0.isImportingAccount = false
        }
        await store.finish()
    }

    // MARK: - loadedWalletAccounts

    @MainActor @Test func loadedWalletAccountsSelectsTheImportedAccount() async {
        let first = Self.walletAccount(idByte: 0x01)
        let second = Self.walletAccount(idByte: 0x02)
        var state = AddLedgerHWWallet.State()
        state.$walletAccounts.withLock { $0 = [] }
        state.$selectedWalletAccount.withLock { $0 = nil }
        let store = TestStore(initialState: state) { AddLedgerHWWallet() }

        await store.send(.loadedWalletAccounts([first, second], second.id)) {
            $0.$walletAccounts.withLock { $0 = [first, second] }
            $0.$selectedWalletAccount.withLock { $0 = second }
        }
    }

    // MARK: - Disconnecting on exit

    @MainActor @Test func leavingTheFlowDisconnectsTheLedger() async {
        let disconnectCount = LockIsolated(0)
        let store = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.ledgerClient.disconnect = { disconnectCount.withValue { $0 += 1 } }
        }

        await store.send(.forgetThisDeviceTapped)
        await store.finish()
        #expect(disconnectCount.value == 1)

        await store.send(.backToHomeTapped)
        await store.finish()
        #expect(disconnectCount.value == 2)

        await store.send(.closeTapped)
        await store.finish()
        #expect(disconnectCount.value == 3)

        await store.send(.accountImportSucceeded)
        await store.finish()
        #expect(disconnectCount.value == 4)
    }

    // MARK: - Helpers

    /// `LedgerAccountBinding`'s device identity is `tpk0-` plus 64 lowercase hex digits, validated
    /// through the linked FFI — same fixture shape as LedgerSessionTests.
    private static func makePairingFixture() throws -> LedgerPairing {
        LedgerPairing(
            ufvk: "utest1fixture",
            binding: LedgerAccountBinding(
                deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-" + String(repeating: "a", count: 64)),
                zip32AccountIndex: Zip32AccountIndex(0)
            ),
            appVersion: "3.9.3"
        )
    }

    private static func walletAccount(idByte: UInt8) -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
            name: "Ledger",
            keySource: Account.ledgerKeySource,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
            uivk: nil
        ))
    }
}
