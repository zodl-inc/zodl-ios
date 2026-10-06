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

    // MOB-2020: a rescan starts from an empty list, so a selection from the scan it replaces
    // must not survive it either -- otherwise Connect or "Try again" could stay enabled for a
    // device that is no longer listed.
    @MainActor @Test func startScanningClearsAnExistingSelection() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        state.devices = [device]
        state.selectedDevice = device
        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            $0.ledgerClient.scanDevices = {
                AsyncThrowingStream { continuation in
                    continuation.finish()
                }
            }
        }

        await store.send(.startScanning) {
            $0.isScanning = true
            $0.issue = nil
            $0.devices = []
            $0.selectedDevice = nil
        }
        await store.send(.stopScanning) {
            $0.isScanning = false
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

    // MARK: - isShowingSearchingCopy (MOB-2020: Android `LedgerDeviceScanVM.pageCopy`)

    @MainActor @Test func isShowingSearchingCopyIsTrueWhileScanningWithNoDevices() async {
        var state = AddLedgerHWWallet.State()
        state.isScanning = true

        #expect(state.isShowingSearchingCopy)
    }

    @MainActor @Test func isShowingSearchingCopyIsFalseOnceTheScanHasFailedOrTimedOutWithNoDevices() async {
        var state = AddLedgerHWWallet.State()
        state.isScanning = false
        state.issue = .noDevicesFound

        #expect(!state.isShowingSearchingCopy)
    }

    @MainActor @Test func isShowingSearchingCopyIsFalseWhenDevicesAreListed() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        state.isScanning = true
        state.devices = [device]

        #expect(!state.isShowingSearchingCopy)
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

    @MainActor @Test func aSignalStrengthUpdateKeepsTheSelection() async {
        // An advertising Ledger is republished every time its signal strength changes, so the
        // selection has to follow the device's identifier, not the value it had when tapped.
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -48)
        let weaker = LedgerBluetoothDevice(id: device.id, name: "Nano X", model: .nanoX, rssi: -51)
        var state = AddLedgerHWWallet.State()
        state.devices = [device]
        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        }

        await store.send(.deviceTapped(device)) {
            $0.selectedDevice = device
        }
        await store.send(.devicesUpdated([weaker])) {
            $0.devices = [weaker]
            $0.selectedDevice = weaker
        }
    }

    // MOB-2020 (Android LedgerDeviceScanVM.kt:446-450): a selection the scan no longer lists --
    // the device went out of range or stopped advertising -- is dropped rather than kept stale.
    @MainActor @Test func aBatchWithoutTheSelectedIdClearsTheSelection() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -48)
        let other = LedgerBluetoothDevice(id: UUID(), name: "Nano X B", model: .nanoX, rssi: -55)
        var state = AddLedgerHWWallet.State()
        state.devices = [device]
        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        }

        await store.send(.deviceTapped(device)) {
            $0.selectedDevice = device
        }
        await store.send(.devicesUpdated([other])) {
            $0.devices = [other]
            $0.selectedDevice = nil
        }
    }

    // Android disables the rows while connecting: a tap on another row must not swap the
    // selection out from under a bond that is already running.
    @MainActor @Test func tappingARowWhileBondingIsIgnored() async {
        let deviceA = LedgerBluetoothDevice(id: UUID(), name: "Nano X A", model: .nanoX, rssi: -40)
        let deviceB = LedgerBluetoothDevice(id: UUID(), name: "Nano X B", model: .nanoX, rssi: -55)
        var state = AddLedgerHWWallet.State()
        state.isConnecting = true
        state.devices = [deviceA, deviceB]
        state.selectedDevice = deviceA
        // No ledgerClient override: an ignored tap must never touch the transport, or a reach
        // into bond would trip "has no test implementation".
        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        }

        await store.send(.deviceTapped(deviceB))
        await store.finish()
    }

    // MARK: - approveOnDeviceTapped (MOB-2020: the picker's own Connect, Android aac01e65)

    @MainActor @Test func approveOnDeviceTappedBondsAndReportsWhetherTheAppIsRunning() async throws {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device
        state.isScanning = true

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.ledgerClient.bond = { bondedDevice in
                #expect(bondedDevice == device)
                return true
            }
        }

        await store.send(.approveOnDeviceTapped) {
            $0.isConnecting = true
            $0.issue = nil
            $0.isScanning = false
        }
        await store.receive(.deviceBonded(device: device, isZcashAppRunning: true)) {
            $0.isConnecting = false
        }
        await store.finish()
    }

    @MainActor @Test func approveOnDeviceTappedIsIgnoredWithoutASelection() async {
        // selectedDevice is nil; no ledgerClient override, so a reach into bond would trip "has
        // no test implementation" and fail the test.
        let store = TestStore(initialState: AddLedgerHWWallet.State()) {
            AddLedgerHWWallet()
        }

        await store.send(.approveOnDeviceTapped)
        await store.finish()
    }

    @MainActor @Test func approveOnDeviceTappedIsIgnoredWhileBusy() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)

        var connectingState = AddLedgerHWWallet.State()
        connectingState.selectedDevice = device
        connectingState.isConnecting = true
        let connectingStore = TestStore(initialState: connectingState) {
            AddLedgerHWWallet()
        }
        await connectingStore.send(.approveOnDeviceTapped)
        await connectingStore.finish()

        var pairingState = AddLedgerHWWallet.State()
        pairingState.selectedDevice = device
        pairingState.isPairing = true
        let pairingStore = TestStore(initialState: pairingState) {
            AddLedgerHWWallet()
        }
        await pairingStore.send(.approveOnDeviceTapped)
        await pairingStore.finish()
    }

    @MainActor @Test func aBondFailureShowsPairingFailedAndKeepsTheSelection() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device
        state.devices = [device]

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.ledgerClient.bond = { _ in throw ZcashError.ledgerTimeout }
        }

        await store.send(.approveOnDeviceTapped) {
            $0.isConnecting = true
            $0.issue = nil
        }
        await store.receive(.pairingFailed(issue: .pairingFailed, connectionLost: true)) {
            $0.isConnecting = false
            $0.issue = .pairingFailed
            $0.isIssueSheetPresented = true
        }
        await store.finish()

        #expect(store.state.selectedDevice == device)
        #expect(store.state.devices == [device])
    }

    // MOB-2020 (Android e3480698): a locked device's refusal to bond's app query shows Unlock
    // Your Ledger, distinct from every other bond failure's Pairing Failed.
    @MainActor @Test func aLockedDeviceShowsUnlockYourLedger() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.ledgerClient.bond = { _ in throw ZcashError.ledgerDeviceRefused(0x5515, true) }
        }

        await store.send(.approveOnDeviceTapped) {
            $0.isConnecting = true
            $0.issue = nil
        }
        await store.receive(.pairingFailed(issue: .deviceLocked, connectionLost: true)) {
            $0.isConnecting = false
            $0.issue = .deviceLocked
            $0.isIssueSheetPresented = true
        }
        await store.finish()
    }

    // MOB-2020: Try again on the picker (no isApproveScreen) with a kept selection bonds that
    // same device again, rather than rescanning.
    @MainActor @Test func retryAfterABondFailureBondsTheSameDeviceAgain() async throws {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device
        state.issue = .pairingFailed
        state.isIssueSheetPresented = true
        let bondCallCount = LockIsolated(0)

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.ledgerClient.bond = { bondedDevice in
                bondCallCount.withValue { $0 += 1 }
                #expect(bondedDevice == device)
                return false
            }
        }

        await store.send(.issuePrimaryTapped) {
            $0.isIssueSheetPresented = false
        }
        await store.receive(\.approveOnDeviceTapped) {
            $0.isConnecting = true
            $0.issue = nil
        }
        await store.receive(.deviceBonded(device: device, isZcashAppRunning: false)) {
            $0.isConnecting = false
        }
        await store.finish()

        #expect(bondCallCount.value == 1)
    }

    // MARK: - openZcashAppTapped (step 3, MOB-2020, Android 8cf16518/b8175064)

    @MainActor @Test func openZcashAppTappedOpensTheAppAndReportsSuccess() async throws {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device
        state.autoOpenZcashApp = true

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            $0.ledgerClient.openZcashApp = { openedDevice in
                #expect(openedDevice == device)
            }
        }

        await store.send(.openZcashAppTapped) {
            $0.autoOpenZcashApp = false
            $0.isOpeningApp = true
            $0.issue = nil
        }
        await store.receive(\.zcashAppOpened) {
            $0.isOpeningApp = false
        }
        await store.finish()
    }

    @MainActor @Test func openZcashAppTappedIsIgnoredWhileAlreadyOpening() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device
        state.isOpeningApp = true
        // No ledgerClient override: a reach into openZcashApp would trip "has no test
        // implementation" and fail the test.
        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        }

        await store.send(.openZcashAppTapped)
        await store.finish()
    }

    @MainActor @Test func aDeclinedOpenShowsOpenAppRejectedAndContinueAsksAgain() async throws {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device
        state.isOpenAppScreen = true
        let openCallCount = LockIsolated(0)

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            $0.ledgerClient.openZcashApp = { _ in
                let call = openCallCount.withValue { $0 += 1; return $0 }
                if call == 1 {
                    throw ZcashError.ledgerAppOpenRejected
                }
            }
        }

        await store.send(.openZcashAppTapped) {
            $0.isOpeningApp = true
            $0.issue = nil
        }
        await store.receive(.openingZcashAppFailed(.openAppRejected)) {
            $0.isOpeningApp = false
            $0.issue = .openAppRejected
            $0.isIssueSheetPresented = true
        }

        // Continue re-asks the device, same action as the on-screen button.
        await store.send(.issuePrimaryTapped) {
            $0.isIssueSheetPresented = false
        }
        await store.receive(\.openZcashAppTapped) {
            $0.isOpeningApp = true
            $0.issue = nil
        }
        await store.receive(\.zcashAppOpened) {
            $0.isOpeningApp = false
        }
        await store.finish()

        #expect(openCallCount.value == 2)
    }

    // MOB-2020: a request that never answers must not keep the flow waiting indefinitely -- the
    // approval-timeout cap wins after five minutes and reads as a lost connection, the same way
    // an unanswered pairing already does.
    @MainActor @Test func theFiveMinuteCapReadsDisconnected() async throws {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        let clock = SignalledClock()
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.continuousClock = clock
            // Never answers -- the on-device confirmation is what the cap is timing.
            $0.ledgerClient.openZcashApp = { _ in
                try await Task.sleep(for: .seconds(999))
                fatalError("cancelled by the approval-timeout race before reaching this point")
            }
        }

        await store.send(.openZcashAppTapped) {
            $0.isOpeningApp = true
            $0.issue = nil
        }
        await clock.sleepDeadlines.countReached(1)
        clock.advance(by: LedgerIssue.approvalTimeout)
        await store.receive(.openingZcashAppFailed(.disconnected)) {
            $0.isOpeningApp = false
            $0.issue = .disconnected
            $0.isIssueSheetPresented = true
        }
        await store.finish()
    }

    @MainActor @Test func cancelTappedCancelsAnInFlightOpenRequest() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        let disconnectCallCount = LockIsolated(0)
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            // Never answers on its own -- cancelTapped must interrupt this, not wait it out.
            $0.ledgerClient.openZcashApp = { _ in
                try await Task.sleep(for: .seconds(999))
                fatalError("cancelled by cancelTapped before reaching this point")
            }
            $0.ledgerClient.disconnect = { disconnectCallCount.withValue { $0 += 1 } }
        }

        await store.send(.openZcashAppTapped) {
            $0.isOpeningApp = true
            $0.issue = nil
        }
        await store.send(.cancelTapped)
        await store.finish()

        #expect(disconnectCallCount.value >= 1)
    }

    // MARK: - connectDeviceTapped (MOB-2020, Android aac01e65/4f7b031e/e838559b: pairDevice)

    @MainActor @Test func connectDeviceTappedPairsAndReportsThePairing() async throws {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        let fixture = try Self.makePairingFixture()
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            // MOB-2020: connectDeviceTapped now races this against the approval-timeout cap;
            // un-advanced, the cap never wins, and the success path below is unaffected by it.
            $0.continuousClock = SignalledClock()
            $0.ledgerClient.pairDevice = { pairedDevice, zip32AccountIndex in
                #expect(pairedDevice == device)
                #expect(zip32AccountIndex == Zip32AccountIndex(0))
                return fixture
            }
        }

        await store.send(.connectDeviceTapped) {
            $0.isPairing = true
            $0.issue = nil
        }
        await store.receive(.pairingSucceeded(fixture)) {
            $0.isPairing = false
            $0.pairing = fixture
        }
        await store.finish()
    }

    // MOB-2020: a pairing request that never answers must not keep the flow waiting indefinitely
    // -- the approval-timeout cap wins after five minutes and reports it the same way a lost
    // connection already is. Unlike the old connect()+pairAccount() pair, pairDevice closes its
    // own transports on every exit (LedgerSession.pairDevice's own `defer`), so there is nothing
    // left for this screen to disconnect.
    @MainActor @Test func connectDeviceTappedTimesOutAfterFiveMinutes() async throws {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        let clock = SignalledClock()
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.continuousClock = clock
            // Never answers -- the on-device approval is what the cap is timing.
            $0.ledgerClient.pairDevice = { _, _ in
                try await Task.sleep(for: .seconds(999))
                fatalError("cancelled by the approval-timeout race before reaching this point")
            }
        }

        await store.send(.connectDeviceTapped) {
            $0.isPairing = true
            $0.issue = nil
        }
        // The timer's sleep is parked (and only then recorded) before advancing to it, so this
        // advance is guaranteed to resume the timer and not race its start.
        await clock.sleepDeadlines.countReached(1)
        clock.advance(by: LedgerIssue.approvalTimeout)
        await store.receive(.pairingFailed(issue: .disconnected, connectionLost: true)) {
            $0.isPairing = false
            $0.issue = .disconnected
            $0.isIssueSheetPresented = true
        }
        await store.finish()
    }

    @MainActor @Test func connectDeviceTappedIsIgnoredWithoutASelection() async {
        // selectedDevice is nil; no ledgerClient override, so a reach into pairDevice would trip
        // "has no test implementation" and fail the test.
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

    @MainActor @Test func deviceRefusalKeepsTheSelectionAndShowsTheMessage() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device
        state.devices = [device]

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            // MOB-2020: connectDeviceTapped now races this against the approval-timeout cap;
            // un-advanced, the cap never wins here.
            $0.continuousClock = SignalledClock()
            $0.ledgerClient.pairDevice = { _, _ in throw ZcashError.ledgerUserRejected }
        }

        await store.send(.connectDeviceTapped) {
            $0.isPairing = true
            $0.issue = nil
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

    // MOB-2020: `pairingFailed` now fires only on the Approve on Your Device screen, which has
    // no scan to fall back on, so a failure -- even one that lost the connection -- always keeps
    // `selectedDevice` and `devices`, letting Retry reconnect the same device. Before this
    // commit a lost connection dropped both, so the picker's now-removed rescan could run.
    @MainActor @Test func pairingFailureKeepsTheSelectedDeviceAndDeviceList() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device
        state.devices = [device]
        state.isPairing = true
        state.isApproveScreen = true

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        }

        await store.send(.pairingFailed(issue: .disconnected, connectionLost: true)) {
            $0.isPairing = false
            $0.issue = .disconnected
            $0.isIssueSheetPresented = true
        }
        await store.finish()

        #expect(store.state.selectedDevice == device)
        #expect(store.state.devices == [device])
    }

    // MOB-2020: the brief's "Retry reconnects to that same device" -- unlike
    // `deviceRefusalKeepsTheSelectionAndShowsTheMessage` (a `connectionLost == false` device
    // refusal, which already kept the selection before this commit), this drives a
    // `connectionLost == true` failure through to a captured device identity on the reconnect.
    @MainActor @Test func retryAfterAConnectionLossReconnectsTheSameDevice() async throws {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        let fixture = try Self.makePairingFixture()
        // Every device `pairDevice` was called with, in call order: fails the first time
        // (producing the connection-lost failure below), succeeds the second (the retry).
        let pairedDevices = LockIsolated<[LedgerBluetoothDevice]>([])
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device
        state.isApproveScreen = true

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            $0.ledgerClient.pairDevice = { pairedDevice, _ in
                let callCount = pairedDevices.withValue {
                    $0.append(pairedDevice)
                    return $0.count
                }
                if callCount == 1 {
                    throw ZcashError.ledgerTimeout
                }
                return fixture
            }
        }

        await store.send(.connectDeviceTapped) {
            $0.isPairing = true
            $0.issue = nil
        }
        await store.receive(.pairingFailed(issue: .disconnected, connectionLost: true)) {
            $0.isPairing = false
            $0.issue = .disconnected
            $0.isIssueSheetPresented = true
        }

        await store.send(.issuePrimaryTapped) {
            $0.isIssueSheetPresented = false
        }
        await store.receive(\.connectDeviceTapped) {
            $0.isPairing = true
            $0.issue = nil
        }
        await store.receive(.pairingSucceeded(fixture)) {
            $0.isPairing = false
            $0.pairing = fixture
        }
        await store.finish()

        #expect(pairedDevices.value == [device, device])
    }

    // MOB-2020: the Approve on Your Device screen's Cancel and back arrow both send this. It
    // must stop the pairing in flight, not merely disconnect while it keeps running unseen --
    // TCA's `Send` silently drops an action sent from an already-cancelled effect (the
    // `Task.isCancelled` guard in `Send.callAsFunction`), so once `CancelId.connectAndPair` is
    // cancelled, neither `pairingFailed` nor `pairingSucceeded` can reach this reducer again --
    // `store.finish()` below proves it, since an unclaimed receive fails it.
    @MainActor @Test func cancelTappedCancelsAnInFlightPairingAndDisconnects() async {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        let disconnectCallCount = LockIsolated(0)
        var state = AddLedgerHWWallet.State()
        state.selectedDevice = device
        state.isApproveScreen = true

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.continuousClock = SignalledClock()
            // Never answers on its own -- cancelTapped must interrupt this, not wait it out.
            $0.ledgerClient.pairDevice = { _, _ in
                try await Task.sleep(for: .seconds(999))
                fatalError("cancelled by cancelTapped before reaching this point")
            }
            $0.ledgerClient.disconnect = { disconnectCallCount.withValue { $0 += 1 } }
        }

        await store.send(.connectDeviceTapped) {
            $0.isPairing = true
            $0.issue = nil
        }
        await store.send(.cancelTapped)
        await store.finish()

        // cancelTapped's own effect always disconnects -- a harmless no-op now that pairDevice
        // never leaves anything open, but still exercised here since cancelTapped is shared with
        // step 3, whose openZcashApp is equally self-contained.
        #expect(disconnectCallCount.value >= 1)
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
        // MOB-2020: this scenario -- a device refusal keeping the connection open -- can now
        // only occur on the Approve on Your Device screen (the picker never reaches
        // `pairingFailed` any more); `issuePrimaryTapped` reads `isApproveScreen`, not
        // `selectedDevice`, to route the retry here.
        state.isApproveScreen = true

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            // Overridden so the run below finishes instead of tripping "has no test
            // implementation" once `.issuePrimaryTapped` re-sends `.connectDeviceTapped`, which
            // (MOB-2020) now races the reconnect against the approval-timeout cap too.
            $0.continuousClock = SignalledClock()
            $0.ledgerClient.pairDevice = { _, _ in fixture }
        }

        await store.send(.issuePrimaryTapped) {
            $0.isIssueSheetPresented = false
        }
        // A device refusal kept the open connection and the selection, so this reconnects the
        // selected device instead of scanning again.
        await store.receive(\.connectDeviceTapped) {
            $0.isPairing = true
            $0.issue = nil
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
        // not the reducer, is what opens Settings. A reach into bond/pairDevice/scanDevices would
        // trip "has no test implementation" and fail the test.
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

    // MOB-2020: before this commit, a binding-write failure left the just-imported SDK account
    // behind with no usable binding -- it could never sign again. Now it is rolled back first.
    @MainActor @Test func bindingStoreFailureReportsAnImportFailure() async throws {
        let fixture = try Self.makePairingFixture()
        var state = AddLedgerHWWallet.State()
        state.pairing = fixture
        let uuid = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))
        let deletedUUIDs = LockIsolated<[AccountUUID]>([])

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer = .mocked(
                importAccount: { _, _, _, _, _, _, _ in uuid },
                deleteAccount: { deletedUUID in deletedUUIDs.withValue { $0.append(deletedUUID) } }
            )
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

        #expect(deletedUUIDs.value == [uuid])
    }

    // MOB-2020: the rollback runs in an unstructured `Task` awaited by `.value` -- not
    // `.cancellableValue` -- specifically so cancelling `unlockTapped`'s own effect (e.g. the
    // user backs out mid-import) does not also cancel the deletion and leave the dead account.
    @MainActor @Test func cancellingTheEffectWhileTheDeletionRunsStillCompletesTheDeletion() async throws {
        let fixture = try Self.makePairingFixture()
        var state = AddLedgerHWWallet.State()
        state.pairing = fixture
        let uuid = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (proceed, proceedContinuation) = AsyncStream<Void>.makeStream()
        let (completed, completedContinuation) = AsyncStream<AccountUUID>.makeStream()

        let store = TestStore(initialState: state) {
            AddLedgerHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer = .mocked(
                importAccount: { _, _, _, _, _, _, _ in uuid },
                deleteAccount: { deletedUUID in
                    enteredContinuation.yield(())
                    for await _ in proceed { break }
                    completedContinuation.yield(deletedUUID)
                }
            )
            $0.walletStorage = .noOp
            $0.walletStorage.importLedgerBinding = { _, _ in
                throw WalletStorage.WalletStorageError.alreadyImported
            }
        }
        store.exhaustivity = .off

        let task = await store.send(.unlockTapped(nil))

        // Waits until the effect is genuinely parked inside `deleteAccount`, not merely started.
        var enteredIterator = entered.makeAsyncIterator()
        await enteredIterator.next()

        // `task.cancel()` cancels the effect's own Task and waits for it to finish unwinding --
        // which, since the rollback is the unstructured `Task` above, only happens once the
        // deletion below completes. Racing the two here avoids a deadlock between them.
        let cancellation = Task { await task.cancel() }
        proceedContinuation.yield(())
        proceedContinuation.finish()
        await cancellation.value

        var completedIterator = completed.makeAsyncIterator()
        let deletedUUID = await completedIterator.next()
        #expect(deletedUUID == uuid)
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
