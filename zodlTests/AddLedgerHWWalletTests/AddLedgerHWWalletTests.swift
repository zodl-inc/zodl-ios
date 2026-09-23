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
// `.timeLimit` is SignalledClock's own backstop (TestSupport/SignalledClock.swift): a wait that
// genuinely never fires is recorded as a failure here instead of hanging the run.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AddLedgerHWWalletTests {
    // MARK: - startScanning

    @MainActor @Test func startScanningForwardsDeviceBatches() async {
        let deviceA = LedgerBluetoothDevice(id: UUID(), name: "Nano X A", model: .nanoX, rssi: -40)
        let deviceB = LedgerBluetoothDevice(id: UUID(), name: "Nano X B", model: .nanoX, rssi: -55)
        let store = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
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
            $0.issue = nil
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

    @MainActor @Test func scanFailureShowsItsIssueSheet() async {
        let store = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            $0.ledgerClient.scanDevices = {
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ZcashError.ledgerBluetoothPoweredOff)
                }
            }
        }

        await store.send(.startScanning) {
            $0.isScanning = true
            $0.issue = nil
            $0.devices = []
        }
        await store.receive(.scanFailed(.bluetoothOff)) {
            $0.isScanning = false
            $0.issue = .bluetoothOff
            $0.isIssueSheetPresented = true
        }
        await store.finish()
    }

    @MainActor @Test func scanTimeoutShowsNoDevicesFound() async {
        let clock = SignalledClock()
        let (scanStream, scanContinuation) = AsyncThrowingStream<[LedgerBluetoothDevice], Error>.makeStream()
        let store = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.continuousClock = clock
            $0.ledgerClient.scanDevices = { scanStream }
        }

        await store.send(.startScanning) {
            $0.isScanning = true
            $0.issue = nil
            $0.devices = []
        }
        // The timer's sleep is parked (and only then recorded) before advancing to it, so this
        // advance is guaranteed to resume the timer and not race its `addTask`.
        await clock.sleepDeadlines.countReached(1)
        clock.advance(by: LedgerIssue.noDevicesFoundTimeout)
        await store.receive(\.scanTimedOut) {
            $0.isScanning = false
            $0.issue = .noDevicesFound
            $0.isIssueSheetPresented = true
        }
        // The timed-out state above already returns `.cancel`, which ends the still-parked scan
        // task's `for await` on its own (a cancelled consumer's iteration ends the sequence).
        // Finishing the continuation here too is redundant but harmless, and avoids leaving it
        // dangling once the test's scope ends.
        scanContinuation.finish()
        await store.finish()
    }

    @MainActor @Test func scanTimeoutIsIgnoredOnceADeviceWasFound() async {
        let clock = SignalledClock()
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        let (scanStream, scanContinuation) = AsyncThrowingStream<[LedgerBluetoothDevice], Error>.makeStream()
        let store = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.continuousClock = clock
            $0.ledgerClient.scanDevices = { scanStream }
        }

        await store.send(.startScanning) {
            $0.isScanning = true
            $0.issue = nil
            $0.devices = []
        }
        scanContinuation.yield([device])
        await store.receive(\.devicesUpdated) {
            $0.devices = [device]
        }
        await clock.sleepDeadlines.countReached(1)
        clock.advance(by: LedgerIssue.noDevicesFoundTimeout)
        // No trailing closure: `.scanTimedOut` is a no-op once a device has turned up, so no
        // state change is expected here.
        await store.receive(\.scanTimedOut)

        await store.send(.stopScanning) {
            $0.isScanning = false
        }
        scanContinuation.finish()
        await store.finish()
    }

    // MARK: - deviceTapped

    @MainActor @Test func deviceTappedOnlySelectsTheDevice() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        // A stale issue (and its sheet) from a previous attempt must be cleared by a fresh
        // selection.
        state.issue = .requestRejected
        state.isIssueSheetPresented = true
        // No ledgerClient override: deviceTapped must never touch the transport, or a call to
        // `connect`/`pairAccount` would trip "has no test implementation".
        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        }

        await store.send(.deviceTapped(device)) {
            $0.selectedDevice = device
            $0.issue = nil
            $0.isIssueSheetPresented = false
        }
    }

    // MARK: - connectDeviceTapped

    @MainActor @Test func connectDeviceTappedConnectsThenPairsAndReportsThePairing() async throws {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        let fixture = try Self.makePairingFixture()
        let callOrder = LockIsolated<[String]>([])
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.ledgerClient.connect = { connectedDevice in
                #expect(connectedDevice == device)
                callOrder.withValue { $0.append("connect") }
            }
            $0.ledgerClient.pairAccount = { zip32AccountIndex in
                #expect(zip32AccountIndex == Zip32AccountIndex(0))
                callOrder.withValue { $0.append("pairAccount") }
                return fixture
            }
        }

        await store.send(.connectDeviceTapped) {
            $0.isConnecting = true
            $0.issue = nil
        }
        await store.receive(\.deviceConnected) {
            $0.isConnecting = false
            $0.isPairing = true
        }
        await store.receive(.pairingSucceeded(fixture)) {
            $0.isPairing = false
            $0.pairing = fixture
        }
        await store.finish()

        #expect(callOrder.value == ["connect", "pairAccount"])
    }

    @MainActor @Test func connectDeviceTappedIsIgnoredWithoutASelection() async {
        // selectedDevice is nil; no ledgerClient override, so a reach into connect/pairAccount
        // would trip "has no test implementation" and fail the test.
        let store = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        }

        await store.send(.connectDeviceTapped)
        await store.finish()
    }

    @MainActor @Test func connectDeviceTappedIsIgnoredWhileBusy() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)

        var connectingState = AddLedgerHWWallet.State()
        connectingState.selectedDevice = device
        connectingState.isConnecting = true
        let connectingStore = TestStore(initialState: connectingState) {
            AddLedgerHWWallet()
        }
        await connectingStore.send(.connectDeviceTapped)
        await connectingStore.finish()

        var pairingState = AddLedgerHWWallet.State()
        pairingState.selectedDevice = device
        pairingState.isPairing = true
        let pairingStore = TestStore(initialState: pairingState) {
            AddLedgerHWWallet()
        }
        await pairingStore.send(.connectDeviceTapped)
        await pairingStore.finish()
    }

    @MainActor @Test func connectFailureIsReportedAsConnectionLostAndRescans() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            // A device-refusal-shaped error thrown from `connect` (rather than `pairAccount`)
            // proves a connect failure is always reported as needing a new connection, regardless
            // of how `LedgerIssue(error).retryNeedsNewConnection` would otherwise classify this
            // same underlying error.
            $0.ledgerClient.connect = { _ in throw ZcashError.ledgerUserRejected }
        }

        await store.send(.connectDeviceTapped) {
            $0.isConnecting = true
            $0.issue = nil
        }
        await store.receive(.pairingFailed(issue: .requestRejected, connectionLost: true)) {
            $0.isConnecting = false
            $0.issue = .requestRejected
            $0.isIssueSheetPresented = true
            $0.selectedDevice = nil
            $0.devices = []
        }
        await store.finish()
    }

    @MainActor @Test func deviceRefusalKeepsTheSelectionAndShowsTheMessage() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device
        state.devices = [device]

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.ledgerClient.connect = { _ in }
            $0.ledgerClient.pairAccount = { _ in throw ZcashError.ledgerUserRejected }
        }

        await store.send(.connectDeviceTapped) {
            $0.isConnecting = true
            $0.issue = nil
        }
        await store.receive(\.deviceConnected) {
            $0.isConnecting = false
            $0.isPairing = true
        }
        await store.receive(.pairingFailed(issue: .requestRejected, connectionLost: false)) {
            $0.isPairing = false
            $0.issue = .requestRejected
            $0.isIssueSheetPresented = true
        }
        await store.finish()

        #expect(store.state.selectedDevice == device)
        #expect(store.state.devices == [device])
    }

    @MainActor @Test func pairingFailureThatLosesTheConnectionDropsTheSelectionAndStopsScanning() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device
        state.devices = [device]
        state.isConnecting = true
        state.isScanning = true

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        }

        await store.send(.pairingFailed(issue: .disconnected, connectionLost: true)) {
            $0.isConnecting = false
            $0.issue = .disconnected
            $0.isIssueSheetPresented = true
            $0.selectedDevice = nil
            $0.devices = []
            $0.isScanning = false
        }
        await store.finish()
    }

    // MARK: - issuePrimaryTapped

    @MainActor @Test func retryAfterAScanFailureRescans() async {
        let store = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            $0.ledgerClient.scanDevices = {
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ZcashError.ledgerBluetoothPoweredOff)
                }
            }
        }

        await store.send(.startScanning) {
            $0.isScanning = true
            $0.issue = nil
            $0.devices = []
        }
        await store.receive(.scanFailed(.bluetoothOff)) {
            $0.isScanning = false
            $0.issue = .bluetoothOff
            $0.isIssueSheetPresented = true
        }

        // No selected device: the sheet's Try again re-scans instead of reconnecting.
        await store.send(.issuePrimaryTapped) {
            $0.isIssueSheetPresented = false
        }
        await store.receive(\.startScanning) {
            $0.isScanning = true
            $0.issue = nil
        }
        await store.receive(.scanFailed(.bluetoothOff)) {
            $0.isScanning = false
            $0.issue = .bluetoothOff
            $0.isIssueSheetPresented = true
        }
        await store.finish()
    }

    @MainActor @Test func retryAfterADeviceRefusalReconnectsTheSelectedDevice() async throws {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        let fixture = try Self.makePairingFixture()
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device
        state.issue = .requestRejected
        state.isIssueSheetPresented = true

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            // Overridden so the run below finishes instead of tripping "has no test
            // implementation" once `.issuePrimaryTapped` re-sends `.connectDeviceTapped`.
            $0.ledgerClient.connect = { _ in }
            $0.ledgerClient.pairAccount = { _ in fixture }
        }

        await store.send(.issuePrimaryTapped) {
            $0.isIssueSheetPresented = false
        }
        // A device refusal kept the open connection and the selection, so this reconnects the
        // selected device instead of scanning again.
        await store.receive(\.connectDeviceTapped) {
            $0.isConnecting = true
            $0.issue = nil
        }
        await store.receive(\.deviceConnected) {
            $0.isConnecting = false
            $0.isPairing = true
        }
        await store.receive(.pairingSucceeded(fixture)) {
            $0.isPairing = false
            $0.pairing = fixture
        }
        await store.finish()
    }

    @MainActor @Test func openSettingsOnlyClosesTheSheet() async {
        var state = AddLedgerHWWallet.State()
        state.issue = .bluetoothUnauthorized
        state.isIssueSheetPresented = true

        // No ledgerClient override: `.bluetoothUnauthorized`'s primary action is `.openSettings`,
        // not `.tryAgain`, so `.issuePrimaryTapped` must only dismiss the sheet here -- the view,
        // not the reducer, is what opens Settings. A reach into connect/pairAccount/scanDevices
        // would trip "has no test implementation" and fail the test.
        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        }

        await store.send(.issuePrimaryTapped) {
            $0.isIssueSheetPresented = false
        }
        await store.finish()
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

    @MainActor @Test func unlockTappedReportsAnAccountThatIsAlreadyInTheWallet() async throws {
        let fixture = try Self.makePairingFixture()
        let existingAccount = Self.walletAccount(idByte: 0x0f)
        var state = AddLedgerHWWallet.State()
        state.pairing = fixture
        state.$walletAccounts.withLock { $0 = [existingAccount] }

        let collisionError = ZcashError.rustImportAccountUfvk(
            """
            Error while initializing accounts: An account corresponding to the data provided already \
            exists in the wallet with UUID AccountUuid(0f0f0f0f-0f0f-0f0f-0f0f-0f0f0f0f0f0f).
            """
        )

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer = .mocked(importAccount: { _, _, _, _, _, _, _ in throw collisionError })
        }

        await store.send(.unlockTapped(nil)) { $0.isImportingAccount = true }
        await store.receive(.accountAlreadyImported(existingAccount)) {
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
