//
//  ConnectHWWalletCoordFlowLedgerTests.swift
//  zodlTests
//
//  Mirrors ConnectHWWalletCoordFlowKeystoneTests: navigation pushes/pops driven by the element
//  screens' own actions, and the failure sheet (show / suppress-behind-success / clear a
//  pending RestoreInfo spinner), now exercised through the merged `ConnectHWWalletCoordFlow`
//  (MOB-2020 UI round 2 -- the flow's root is the vendor chooser, and the Ledger instructions
//  screen that used to be the old AddLedgerHWWalletCoordFlow's own root, along with the device
//  picker/approve/account/device-ready/connected screens, are `Path` elements with the
//  `ledger`-prefixed case names). MOB-2020 (Android 7cd09f72/aa6d098a): the device picker only
//  finds and selects a Ledger now -- Connect pushes the Approve on Your Device screen, which runs
//  the connect-and-pair and carries the coordinator-level navigation this file covers (the
//  collision check, Rebound, Account Already Added, and Cancel popping back to the picker). A
//  scan failure on the picker itself just rescans in place, with no coordinator-level navigation
//  of its own; see AddLedgerHWWalletTests for the element-level pairing/retry/cancel behavior
//  (Features/CoordFlows/ConnectHWWalletCoordFlow*.swift).
//
//  ConnectHWWalletCoordFlow.State is not Equatable (it contains a non-Equatable StackState), so
//  these tests drive a plain Store and read state directly after sending actions -- the same
//  approach ConnectHWWalletCoordFlowKeystoneTests uses.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct ConnectHWWalletCoordFlowLedgerTests {

    // MARK: - Self: connectTapped (the instructions screen, now a path element)

    @Test func connectTappedPushesDevicePicker() async {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .addLedgerHWWallet(.connectTapped))))

        #expect(store.state.path.count == 2)
        #expect(isDevicePicker(store.state.path.last))
    }

    // MARK: - Device Picker

    // MOB-2020 (Android aac01e65): Connect bonds right on the picker (AddLedgerHWWalletStore);
    // this coordinator only reacts to the outcome (`.deviceBonded`), never by sending
    // `.ledgerDevicePicker(.connectDeviceTapped)` directly (see AddLedgerHWWalletStore's
    // `isApproveScreen` doc comment for why).

    // Android efe21904: the device did not already run the Zcash app -- step 3 is pushed alone,
    // set to open it automatically.
    @Test func deviceBondedPushesStep3AutoWhenTheAppIsNotRunning() async throws {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var devicePickerState = AddLedgerHWWallet.State.initial
        devicePickerState.selectedDevice = device
        devicePickerState.isConnecting = true
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.ledgerDevicePicker(devicePickerState))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .ledgerDevicePicker(.deviceBonded(isZcashAppRunning: false)))))

        #expect(store.state.path.count == 2)
        if case .ledgerOpenApp(let openAppState) = store.state.path.last {
            #expect(openAppState.selectedDevice == device)
            #expect(openAppState.autoOpenZcashApp == true)
            #expect(openAppState.isConnecting == false)
        } else {
            Issue.record("expected .ledgerOpenApp to be pushed carrying the selected device")
        }
    }

    // Android aac01e65: the device already ran the Zcash app -- step 3 goes on the stack idle,
    // under step 4, which starts pairing at once as it does from a fresh push.
    @Test func deviceBondedPushesIdleStep3PlusStep4WhenTheAppIsRunning() async throws {
        let device = LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
        var devicePickerState = AddLedgerHWWallet.State.initial
        devicePickerState.selectedDevice = device
        devicePickerState.isConnecting = true
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.ledgerDevicePicker(devicePickerState))
        let fixture = try Self.makePairingFixture()
        let connectedDevices = LockIsolated<[LedgerBluetoothDevice]>([])
        let store = makeStore(initialState: initialState) {
            $0.continuousClock = SignalledClock()
            $0.ledgerClient.connect = { connectedDevice in connectedDevices.withValue { $0.append(connectedDevice) } }
            $0.ledgerClient.pairAccount = { _ in fixture }
        }
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .ledgerDevicePicker(.deviceBonded(isZcashAppRunning: true)))))

        #expect(store.state.path.count == 3)
        if case .ledgerOpenApp(let openAppState) = store.state.path[id: store.state.path.ids[1]] {
            #expect(openAppState.selectedDevice == device)
            #expect(openAppState.autoOpenZcashApp == false)
        } else {
            Issue.record("expected an idle .ledgerOpenApp under the approve screen")
        }
        if case .ledgerApproveOnDevice(let approveState) = store.state.path.last {
            #expect(approveState.selectedDevice == device)
            #expect(approveState.isApproveScreen == true)
        } else {
            Issue.record("expected .ledgerApproveOnDevice to be pushed carrying the selected device")
        }

        // The follow-up `.connectDeviceTapped` this arm sends chains asynchronously -- poll for
        // `ledgerClient.connect` to have been reached instead of asserting synchronously.
        for _ in 0..<50 {
            if !connectedDevices.value.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(connectedDevices.value == [device])
    }

    // MARK: - Ledger Approve on Device

    // MOB-2020 (Android 7cd09f72/aa6d098a): success replaces the approve element in place --
    // never a push -- so backing out of the account screen lands on the picker, as on Android.
    @Test func pairingSucceededOnTheApproveScreenReplacesItWithTheAccountScreen() async throws {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.ledgerApproveOnDevice(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!
        let fixture = try Self.makePairingFixture()

        store.send(.path(.element(id: id, action: .ledgerApproveOnDevice(.pairingSucceeded(fixture)))))

        // Same count as before sending -- a replace, not a push.
        #expect(store.state.path.count == 1)
        if case .ledgerAccount(let accountState) = store.state.path.last {
            #expect(accountState.pairing == fixture)
        } else {
            Issue.record("expected .ledgerAccount to replace the approve element, carrying the pairing")
        }
    }

    @Test func pairingANewLedgerStillShowsItsAccount() async throws {
        var approveState = AddLedgerHWWallet.State.initial
        // No account carries the pairing's UFVK, so the pre-import check must let this through.
        // MOB-2020 (Android d1506d0d): the unrelated account is Keystone-vendored, not Ledger --
        // the wallet holds at most one Ledger account, so a Ledger-vendored one here would now
        // (correctly) trip the new no-target wrong-Ledger guard this same file's
        // `anUnknownKeyWithNoTargetWhileALedgerAccountExistsShowsDeviceMismatch` covers.
        approveState.$walletAccounts.withLock { $0 = [Self.keystoneWalletAccount(idByte: 0x0f, ufvk: "uview1someotherfixture")] }
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerApproveOnDevice(approveState))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.last!
        let fixture = try Self.makePairingFixture(ufvk: "uview1ledgerpairingfixture")

        store.send(.path(.element(id: id, action: .ledgerApproveOnDevice(.pairingSucceeded(fixture)))))

        // Same count as before sending -- a replace, not a push.
        #expect(store.state.path.count == 2)
        if case .ledgerAccount(let accountState) = store.state.path.last {
            #expect(accountState.pairing == fixture)
        } else {
            Issue.record("expected .ledgerAccount to replace the approve element, carrying the pairing")
        }
        #expect(store.state.isAccountAlreadyAddedSheetPresented == false)
        #expect(store.state.alreadyAddedAccount == nil)
    }

    @Test func pairingALedgerAlreadyInTheWalletRaisesAccountAlreadyAddedOnTheApproveScreen() async throws {
        let matchingUFVK = "uview1ledgerpairingfixture"
        let existingAccount = Self.walletAccount(idByte: 0x0f, ufvk: matchingUFVK)
        var approveState = AddLedgerHWWallet.State.initial
        approveState.$walletAccounts.withLock { $0 = [existingAccount] }
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerApproveOnDevice(approveState))
        let fixture = try Self.makePairingFixture(ufvk: matchingUFVK)
        // MOB-2020 (Rebound): this account already has a binding, so the approve screen still
        // raises "Account Already Added" -- `.noOp`'s own `exportLedgerBinding` throws
        // `uninitializedLedgerBinding` by default, which would otherwise take the Rebound branch
        // (see `pairingAnUnboundExistingLedgerAccountReboundsItAndLeavesTheFlow` below).
        let store = makeStore(initialState: initialState) {
            $0.walletStorage.exportLedgerBinding = { _ in fixture.binding }
        }
        let id = store.state.path.ids.last!

        store.send(.path(.element(id: id, action: .ledgerApproveOnDevice(.pairingSucceeded(fixture)))))

        // The collision check (and, for an unbound match, the rebind) now runs in an effect --
        // poll for it to land instead of asserting synchronously right after `send`.
        for _ in 0..<50 {
            if store.state.isAccountAlreadyAddedSheetPresented { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.state.alreadyAddedAccount == existingAccount)
        #expect(store.state.isAccountAlreadyAddedSheetPresented == true)
        // The path still ends at the approve screen -- the collision arm neither pushes nor
        // replaces anything, so the underlying screen shows its header with Cancel only, under
        // the sheet.
        #expect(store.state.path.count == 2)
        #expect(isApproveOnDevice(store.state.path.last))
    }

    // MOB-2020 (Android b013b7c2, Rebound): an unbound match can never sign again, so pairing
    // stores the new binding onto it instead of dead-ending on "Account Already Added".
    @Test func pairingAnUnboundExistingLedgerAccountReboundsItAndLeavesTheFlow() async throws {
        let matchingUFVK = "uview1ledgerpairingfixture"
        let existingAccount = Self.walletAccount(idByte: 0x0f, ufvk: matchingUFVK)
        var approveState = AddLedgerHWWallet.State.initial
        approveState.$walletAccounts.withLock { $0 = [existingAccount] }
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerApproveOnDevice(approveState))
        let fixture = try Self.makePairingFixture(ufvk: matchingUFVK)
        let disconnected = LockIsolated(false)
        let importedBinding = LockIsolated<LedgerAccountBinding?>(nil)
        let importedAccountId = LockIsolated<AccountUUID?>(nil)
        // `.noOp`'s own `exportLedgerBinding` already throws `uninitializedLedgerBinding`
        // (unbound) and its `importLedgerBinding` already succeeds silently -- only the write
        // itself needs capturing here.
        let store = makeStore(initialState: initialState) {
            $0.ledgerClient.disconnect = { disconnected.setValue(true) }
            $0.walletStorage.importLedgerBinding = { binding, accountId in
                importedBinding.setValue(binding)
                importedAccountId.setValue(accountId)
            }
        }
        let id = store.state.path.ids.last!

        store.send(.path(.element(id: id, action: .ledgerApproveOnDevice(.pairingSucceeded(fixture)))))

        for _ in 0..<50 {
            if store.state.alreadyAddedAccount != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.state.alreadyAddedAccount == existingAccount)
        // Unlike a bound match, no sheet is ever shown.
        #expect(store.state.isAccountAlreadyAddedSheetPresented == false)
        #expect(importedAccountId.value == existingAccount.id)
        #expect(importedBinding.value == fixture.binding)

        // Leaves exactly the way `goToExistingAccountTapped` does:
        // `.addLedgerHWWallet(.backToHomeTapped)` disconnects the Ledger inside its own effect.
        for _ in 0..<50 {
            if disconnected.value { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(disconnected.value)
    }

    // MOB-2020 (Android b013b7c2, Rebound): a binding write that fails must not strand the user --
    // it falls back to today's "Account Already Added", exactly as if the account had a binding.
    @Test func aFailedRebindStillRaisesAccountAlreadyAddedOnTheApproveScreen() async throws {
        struct BindingWriteFailure: Error {}
        let matchingUFVK = "uview1ledgerpairingfixture"
        let existingAccount = Self.walletAccount(idByte: 0x0f, ufvk: matchingUFVK)
        var approveState = AddLedgerHWWallet.State.initial
        approveState.$walletAccounts.withLock { $0 = [existingAccount] }
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerApproveOnDevice(approveState))
        let fixture = try Self.makePairingFixture(ufvk: matchingUFVK)
        // `exportLedgerBinding` keeps `.noOp`'s unbound default; only the store itself fails.
        let store = makeStore(initialState: initialState) {
            $0.walletStorage.importLedgerBinding = { _, _ in throw BindingWriteFailure() }
        }
        let id = store.state.path.ids.last!

        store.send(.path(.element(id: id, action: .ledgerApproveOnDevice(.pairingSucceeded(fixture)))))

        for _ in 0..<50 {
            if store.state.isAccountAlreadyAddedSheetPresented { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.state.alreadyAddedAccount == existingAccount)
        #expect(store.state.isAccountAlreadyAddedSheetPresented == true)
        #expect(store.state.path.count == 2)
        #expect(isApproveOnDevice(store.state.path.last))
    }

    // MARK: - Ledger Approve on Device: repair mode (MOB-2020, Android d1506d0d/6bef6fd2)
    //
    // `ledgerRepairTarget` is what Root sets when the sign sheet's Pair Ledger opens this flow to
    // pair a specific account again -- see RootLedgerShieldingSheetTests.swift for Root's own side
    // of staging it.

    @Test func repairingTheTargetWithItsOwnLedgerReplacesTheBindingAndLeavesTheFlow() async throws {
        let matchingUFVK = "uview1ledgerpairingfixture"
        let target = Self.walletAccount(idByte: 0x0f, ufvk: matchingUFVK)
        var approveState = AddLedgerHWWallet.State.initial
        approveState.$walletAccounts.withLock { $0 = [target] }
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.ledgerRepairTarget = target.id
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerApproveOnDevice(approveState))
        let fixture = try Self.makePairingFixture(ufvk: matchingUFVK)
        let disconnected = LockIsolated(false)
        let calls = LockIsolated<[String]>([])
        let deletedAccountId = LockIsolated<AccountUUID?>(nil)
        let importedAccountId = LockIsolated<AccountUUID?>(nil)
        let importedBinding = LockIsolated<LedgerAccountBinding?>(nil)
        // `.noOp`'s own `exportLedgerBinding` already throws `uninitializedLedgerBinding` -- the
        // target's stored binding is missing or unusable, the very reason Pair Ledger was tapped.
        let store = makeStore(initialState: initialState) {
            $0.ledgerClient.disconnect = { disconnected.setValue(true) }
            $0.walletStorage.exportLedgerBinding = { _ in
                calls.withValue { $0.append("export") }
                throw WalletStorage.WalletStorageError.uninitializedLedgerBinding
            }
            $0.walletStorage.deleteLedgerBinding = { accountId in
                calls.withValue { $0.append("delete") }
                deletedAccountId.setValue(accountId)
            }
            $0.walletStorage.importLedgerBinding = { binding, accountId in
                calls.withValue { $0.append("import") }
                importedAccountId.setValue(accountId)
                importedBinding.setValue(binding)
            }
        }
        let id = store.state.path.ids.last!

        store.send(.path(.element(id: id, action: .ledgerApproveOnDevice(.pairingSucceeded(fixture)))))

        // MOB-2020: target cleared synchronously, before the store effect even starts -- its only
        // job (deciding whether this Ledger was the right one) is already settled.
        #expect(store.state.ledgerRepairTarget == nil)

        for _ in 0..<50 {
            if store.state.alreadyAddedAccount != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.state.alreadyAddedAccount == target)
        // Unlike a bound match on the no-target path, no sheet is ever shown -- same as Rebound.
        #expect(store.state.isAccountAlreadyAddedSheetPresented == false)
        // Deleted (a missing binding is fine) before importing, for the target's id.
        #expect(calls.value == ["export", "delete", "import"])
        #expect(deletedAccountId.value == target.id)
        #expect(importedAccountId.value == target.id)
        #expect(importedBinding.value == fixture.binding)

        // Leaves exactly the way Rebound always has.
        for _ in 0..<50 {
            if disconnected.value { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(disconnected.value)
    }

    // MOB-2020 (Android 6bef6fd2): a BOUND target still gets its binding replaced -- the stored
    // one may be unusable, which is exactly why Pair Ledger was offered in the first place.
    @Test func repairingABoundTargetAgainReplacesItsBindingRegardless() async throws {
        let matchingUFVK = "uview1ledgerpairingfixture"
        let target = Self.walletAccount(idByte: 0x0f, ufvk: matchingUFVK)
        var approveState = AddLedgerHWWallet.State.initial
        approveState.$walletAccounts.withLock { $0 = [target] }
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.ledgerRepairTarget = target.id
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerApproveOnDevice(approveState))
        let fixture = try Self.makePairingFixture(ufvk: matchingUFVK)
        let existingBinding = LedgerAccountBinding(
            deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-" + String(repeating: "b", count: 64)),
            zip32AccountIndex: Zip32AccountIndex(0)
        )
        let importedBinding = LockIsolated<LedgerAccountBinding?>(nil)
        let store = makeStore(initialState: initialState) {
            $0.walletStorage.exportLedgerBinding = { _ in existingBinding }
            $0.walletStorage.importLedgerBinding = { binding, _ in importedBinding.setValue(binding) }
        }
        let id = store.state.path.ids.last!

        store.send(.path(.element(id: id, action: .ledgerApproveOnDevice(.pairingSucceeded(fixture)))))

        for _ in 0..<50 {
            if store.state.alreadyAddedAccount != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.state.alreadyAddedAccount == target)
        #expect(store.state.isAccountAlreadyAddedSheetPresented == false)
        #expect(importedBinding.value == fixture.binding)
    }

    // MOB-2020: a failing store must not strand the user, and must not leave the account worse
    // off than before the attempt -- the old binding (read back before the delete) is restored,
    // and the approve screen falls back to "Account Already Added", same as the no-target rebind.
    @Test func aFailedRepairStoreRestoresTheOldBindingAndShowsAlreadyAdded() async throws {
        struct BindingWriteFailure: Error {}
        let matchingUFVK = "uview1ledgerpairingfixture"
        let target = Self.walletAccount(idByte: 0x0f, ufvk: matchingUFVK)
        var approveState = AddLedgerHWWallet.State.initial
        approveState.$walletAccounts.withLock { $0 = [target] }
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.ledgerRepairTarget = target.id
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerApproveOnDevice(approveState))
        let fixture = try Self.makePairingFixture(ufvk: matchingUFVK)
        let oldBinding = LedgerAccountBinding(
            deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-" + String(repeating: "b", count: 64)),
            zip32AccountIndex: Zip32AccountIndex(0)
        )
        let importCount = LockIsolated(0)
        let restoredBinding = LockIsolated<LedgerAccountBinding?>(nil)
        let store = makeStore(initialState: initialState) {
            $0.walletStorage.exportLedgerBinding = { _ in oldBinding }
            $0.walletStorage.importLedgerBinding = { binding, _ in
                let call = importCount.withValue { $0 += 1; return $0 }
                if call == 1 {
                    throw BindingWriteFailure()
                }
                restoredBinding.setValue(binding)
            }
        }
        let id = store.state.path.ids.last!

        store.send(.path(.element(id: id, action: .ledgerApproveOnDevice(.pairingSucceeded(fixture)))))

        for _ in 0..<50 {
            if store.state.isAccountAlreadyAddedSheetPresented { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.state.alreadyAddedAccount == target)
        #expect(store.state.isAccountAlreadyAddedSheetPresented == true)
        #expect(store.state.ledgerRepairTarget == nil)
        #expect(importCount.value == 2)
        #expect(restoredBinding.value == oldBinding)
        #expect(store.state.path.count == 2)
        #expect(isApproveOnDevice(store.state.path.last))
    }

    // MOB-2020: pairing the target again with any other Ledger is the wrong Ledger -- reported on
    // the approve screen directly, never imported. The target stays set so Retry repairs again.
    @Test func repairingTheTargetWithAnotherLedgerShowsDeviceMismatchAndStoresNothing() async throws {
        let target = Self.walletAccount(idByte: 0x0f, ufvk: "uview1ledgerpairingfixture")
        var approveState = AddLedgerHWWallet.State.initial
        approveState.$walletAccounts.withLock { $0 = [target] }
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.ledgerRepairTarget = target.id
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerApproveOnDevice(approveState))
        let fixture = try Self.makePairingFixture(ufvk: "uview1someotherfixture")
        let importCalled = LockIsolated(false)
        let deleteCalled = LockIsolated(false)
        let store = makeStore(initialState: initialState) {
            $0.walletStorage.importLedgerBinding = { _, _ in importCalled.setValue(true) }
            $0.walletStorage.deleteLedgerBinding = { _ in deleteCalled.setValue(true) }
        }
        let id = store.state.path.ids.last!

        store.send(.path(.element(id: id, action: .ledgerApproveOnDevice(.pairingSucceeded(fixture)))))

        #expect(store.state.path.count == 2)
        if case .ledgerApproveOnDevice(let finalApproveState) = store.state.path.last {
            #expect(finalApproveState.issue == .deviceMismatch)
            #expect(finalApproveState.isIssueSheetPresented == true)
        } else {
            Issue.record("expected .ledgerApproveOnDevice to stay in place, showing the issue")
        }
        #expect(store.state.ledgerRepairTarget == target.id)
        #expect(store.state.isAccountAlreadyAddedSheetPresented == false)
        #expect(store.state.alreadyAddedAccount == nil)
        #expect(importCalled.value == false)
        #expect(deleteCalled.value == false)
    }

    // MOB-2020 (Android d1506d0d): with no target (adding a Ledger, not repairing one), a key
    // that matches no account while the wallet already holds a Ledger account is the wrong
    // Ledger too -- the wallet holds at most one, so this can't be a second account to add.
    @Test func anUnknownKeyWithNoTargetWhileALedgerAccountExistsShowsDeviceMismatch() async throws {
        let existingLedgerAccount = Self.walletAccount(idByte: 0x0f, ufvk: "uview1existingledger")
        var approveState = AddLedgerHWWallet.State.initial
        approveState.$walletAccounts.withLock { $0 = [existingLedgerAccount] }
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerApproveOnDevice(approveState))
        let fixture = try Self.makePairingFixture(ufvk: "uview1anotherledger")
        let importCalled = LockIsolated(false)
        let store = makeStore(initialState: initialState) {
            $0.walletStorage.importLedgerBinding = { _, _ in importCalled.setValue(true) }
        }
        let id = store.state.path.ids.last!

        store.send(.path(.element(id: id, action: .ledgerApproveOnDevice(.pairingSucceeded(fixture)))))

        #expect(store.state.path.count == 2)
        if case .ledgerApproveOnDevice(let finalApproveState) = store.state.path.last {
            #expect(finalApproveState.issue == .deviceMismatch)
            #expect(finalApproveState.isIssueSheetPresented == true)
        } else {
            Issue.record("expected .ledgerApproveOnDevice to stay in place, showing the issue")
        }
        #expect(store.state.ledgerRepairTarget == nil)
        #expect(importCalled.value == false)
    }

    // MARK: - Ledger Approve on Device: Cancel

    // MOB-2020: Cancel (and the approve screen's own back arrow, which sends the same action)
    // pops back to the picker. The element's own reducer (AddLedgerHWWalletStore) disconnects and
    // cancels the pairing; this coordinator only pops -- see ConnectHWWalletCoordFlowStore's
    // `.cancelTapped` arm for why that split exists.
    @Test func cancelOnTheApproveScreenDisconnectsAndPopsBackToThePicker() async throws {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.ledgerDevicePicker(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerApproveOnDevice(AddLedgerHWWallet.State.initial))
        let disconnected = LockIsolated(false)
        let store = makeStore(initialState: initialState) {
            $0.ledgerClient.disconnect = { disconnected.setValue(true) }
        }
        let id = store.state.path.ids.last!

        store.send(.path(.element(id: id, action: .ledgerApproveOnDevice(.cancelTapped))))

        #expect(store.state.path.count == 1)
        #expect(isDevicePicker(store.state.path.last))

        for _ in 0..<50 {
            if disconnected.value { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(disconnected.value)
    }

    // MARK: - Account

    @Test func nextTappedPushesDeviceReadyCarryingTheAccountState() async {
        var accountState = AddLedgerHWWallet.State.initial
        accountState.isAccountSelected = true
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.ledgerAccount(accountState))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .ledgerAccount(.nextTapped))))

        #expect(store.state.path.count == 2)
        if case .ledgerDeviceReady(let deviceReadyState) = store.state.path.last {
            #expect(deviceReadyState.isAccountSelected == true)
        } else {
            Issue.record("expected .ledgerDeviceReady to be pushed carrying the account state")
        }
    }

    // MARK: - Device Ready: accountImportSucceeded

    @Test func accountImportSucceededPushesConnectedScreen() async {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.ledgerDeviceReady(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .ledgerDeviceReady(.accountImportSucceeded))))

        #expect(store.state.path.count == 2)
        #expect(isConnected(store.state.path.last))
    }

    // MARK: - Device Ready: accountImportFailed

    @Test func accountImportFailedShowsFailureSheet() async {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.ledgerDeviceReady(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .ledgerDeviceReady(.accountImportFailed("boom")))))

        #expect(store.state.isFailureSheetPresented == true)
        #expect(store.state.errMsg == "boom")
    }

    @Test func accountImportFailedAfterSuccessScreenIsIgnored() async {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.ledgerDeviceReady(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerConnected(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .ledgerDeviceReady(.accountImportFailed("duplicate")))))

        #expect(store.state.isFailureSheetPresented == false)
        #expect(store.state.errMsg.isEmpty)
    }

    @Test func accountImportFailedAfterSuccessScreenStillClearsRestoreInfoProcessing() async {
        // Even when the failure sheet is suppressed (success screen on the stack), any
        // RestoreInfo element must not be left with a stuck spinner.
        var restoreInfoState = RestoreInfo.State.initial
        restoreInfoState.isKeystoneFlow = true
        restoreInfoState.isProcessing = true
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.ledgerDeviceReady(AddLedgerHWWallet.State.initial))
        initialState.path.append(.restoreInfo(restoreInfoState))
        initialState.path.append(.ledgerConnected(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .ledgerDeviceReady(.accountImportFailed("duplicate")))))

        #expect(store.state.isFailureSheetPresented == false)
        #expect(store.state.errMsg.isEmpty)
        let restoreInfoIsProcessing = store.state.path.compactMap {
            if case .restoreInfo(let element) = $0 { element.isProcessing } else { nil }
        }.first
        #expect(restoreInfoIsProcessing == false)
    }

    // MARK: - Device Ready: accountAlreadyImported

    @Test func accountAlreadyImportedShowsTheAccountAlreadyAddedSheet() async {
        let account = Self.walletAccount(idByte: 0x0f)
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.ledgerDeviceReady(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .ledgerDeviceReady(.accountAlreadyImported(account)))))

        #expect(store.state.isAccountAlreadyAddedSheetPresented == true)
        #expect(store.state.alreadyAddedAccount == account)
    }

    // MARK: - cancelFailureTapped

    @Test func cancelFailureTappedHidesSheet() async {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.isFailureSheetPresented = true
        let store = makeStore(initialState: initialState)

        store.send(.cancelFailureTapped)

        #expect(store.state.isFailureSheetPresented == false)
    }

    // MARK: - accountAlreadyAddedCancelTapped / goToExistingAccountTapped

    @Test func accountAlreadyAddedCancelLeavesTheFlow() async throws {
        let disconnected = LockIsolated(false)
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.isAccountAlreadyAddedSheetPresented = true
        initialState.alreadyAddedAccount = Self.walletAccount(idByte: 0x0f)

        let store = makeStore(initialState: initialState) {
            $0.ledgerClient.disconnect = { disconnected.setValue(true) }
        }

        store.send(.accountAlreadyAddedCancelTapped)

        #expect(store.state.isAccountAlreadyAddedSheetPresented == false)

        // `.backToHomeTapped` disconnects the Ledger inside AddLedgerHWWallet's own `.run` effect
        // -- poll for the spy rather than asserting synchronously.
        for _ in 0..<50 {
            if disconnected.value { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(disconnected.value)
    }

    @Test func goToExistingAccountLeavesTheFlowAndKeepsTheAccount() async throws {
        let disconnected = LockIsolated(false)
        let account = Self.walletAccount(idByte: 0x0f)
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.isAccountAlreadyAddedSheetPresented = true
        initialState.alreadyAddedAccount = account

        let store = makeStore(initialState: initialState) {
            $0.ledgerClient.disconnect = { disconnected.setValue(true) }
        }

        store.send(.goToExistingAccountTapped)

        #expect(store.state.isAccountAlreadyAddedSheetPresented == false)
        // Unlike the cancel above, the account must survive so Root can read it.
        #expect(store.state.alreadyAddedAccount == account)

        for _ in 0..<50 {
            if disconnected.value { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(disconnected.value)
    }

    // MARK: - contactSupportTapped

    @Test func contactSupportTappedWithMailCapabilitySetsSupportData() async {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.isFailureSheetPresented = true
        initialState.canSendMail = true
        initialState.errMsg = "ZLEDG0002: some ledger error"
        let store = makeStore(initialState: initialState)

        store.send(.contactSupportTapped)

        #expect(store.state.isFailureSheetPresented == false)
        #expect(store.state.supportData != nil)
    }

    @Test func contactSupportTappedWithoutMailSetsMessageToBeShared() async {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.isFailureSheetPresented = true
        initialState.canSendMail = false
        initialState.errMsg = "ZLEDG0002: some ledger error"
        let store = makeStore(initialState: initialState)

        store.send(.contactSupportTapped)

        #expect(store.state.isFailureSheetPresented == false)
        #expect(store.state.messageToBeShared != nil)
    }

    // MARK: - Mail / share cleanup

    @Test func sendSupportMailFinishedClearsSupportData() async {
        var initialState = ConnectHWWalletCoordFlow.State()
        // generate() reads walletStorage; this call runs in test code, outside the store's
        // dependency scope, so it needs its own override.
        initialState.supportData = withDependencies {
            $0.walletStorage = .noOp
        } operation: {
            SupportDataGenerator.generate("")
        }
        let store = makeStore(initialState: initialState)

        store.send(.sendSupportMailFinished)

        #expect(store.state.supportData == nil)
    }

    @Test func shareFinishedClearsMessageToBeShared() async {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.messageToBeShared = "some message"
        let store = makeStore(initialState: initialState)

        store.send(.shareFinished)

        #expect(store.state.messageToBeShared == nil)
    }

    // MARK: - Full unlock -> success screen

    @Test func unlockTappedPushesConnectedScreenWithoutFailureSheet() async throws {
        let fixture = try Self.makePairingFixture()
        var deviceReadyState = AddLedgerHWWallet.State.initial
        deviceReadyState.pairing = fixture
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.ledgerDeviceReady(deviceReadyState))

        let importCount = LockIsolated(0)
        let uuid = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))
        let store = Store(initialState: initialState) {
            ConnectHWWalletCoordFlow()
        } withDependencies: {
            $0.walletStorage = .noOp
            $0.ledgerClient = .noOp
            $0.sdkSynchronizer = .mocked(
                importAccount: { _, _, _, _, _, _, _ in
                    importCount.withValue { $0 += 1 }
                    return uuid
                },
                walletAccounts: { [] }
            )
        }
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .ledgerDeviceReady(.unlockTapped(nil)))))

        // Effects chain asynchronously (unlockTapped -> accountImported -> accountImportSucceeded
        // -> the coordinator's push); poll until the success screen lands or we give up.
        for _ in 0..<50 {
            if store.state.path.contains(where: { isConnected($0) }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(importCount.value == 1)
        #expect(store.state.path.contains(where: { isConnected($0) }))
        #expect(store.state.isFailureSheetPresented == false)
        #expect(store.state.errMsg.isEmpty)
    }

    // MARK: - hardwareWalletVendor (MOB-2020: Keystone-branding fix)

    @Test func ledgerBirthdayAndRestoreScreensCarryTheLedgerVendor() async {
        // .ledgerDeviceReady(.setBirthdayTapped) pushes a birthday state carrying .ledger.
        do {
            var initialState = ConnectHWWalletCoordFlow.State()
            initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
            initialState.path.append(.ledgerDeviceReady(AddLedgerHWWallet.State.initial))
            let store = makeStore(initialState: initialState)
            let deviceReadyId = store.state.path.ids.last!

            store.send(.path(.element(id: deviceReadyId, action: .ledgerDeviceReady(.setBirthdayTapped))))

            #expect(store.state.path.count == 3)
            if case .estimateBirthdaysDate(let birthdayState) = store.state.path.last {
                #expect(birthdayState.hardwareWalletVendor == .ledger)
            } else {
                Issue.record("expected .estimateBirthdaysDate to be pushed")
            }
        }

        // .estimateBirthdaysDate(.enterManuallyTapped) pushes a manual birthday state carrying .ledger.
        do {
            var initialState = ConnectHWWalletCoordFlow.State()
            initialState.path.append(.ledgerDeviceReady(AddLedgerHWWallet.State.initial))
            initialState.path.append(.estimateBirthdaysDate(WalletBirthday.State.initial))
            let store = makeStore(initialState: initialState)
            let estimateId = store.state.path.ids.last!

            store.send(.path(.element(id: estimateId, action: .estimateBirthdaysDate(.enterManuallyTapped))))

            #expect(store.state.path.count == 3)
            if case .walletBirthday(let birthdayState) = store.state.path.last {
                #expect(birthdayState.hardwareWalletVendor == .ledger)
            } else {
                Issue.record("expected .walletBirthday to be pushed")
            }
        }

        // .walletBirthday(.restoreTapped) pushes a restore-info state carrying .ledger.
        do {
            var initialState = ConnectHWWalletCoordFlow.State()
            initialState.path.append(.ledgerDeviceReady(AddLedgerHWWallet.State.initial))
            initialState.path.append(.walletBirthday(WalletBirthday.State.initial))
            let store = makeStore(initialState: initialState)
            let walletBirthdayId = store.state.path.ids.last!

            store.send(.path(.element(id: walletBirthdayId, action: .walletBirthday(.restoreTapped))))

            #expect(store.state.path.count == 3)
            if case .restoreInfo(let restoreInfoState) = store.state.path.last {
                #expect(restoreInfoState.hardwareWalletVendor == .ledger)
            } else {
                Issue.record("expected .restoreInfo to be pushed")
            }
        }

        // .estimatedBirthday(.restoreTapped), from an .estimatedBirthday element that already
        // carries .ledger, pushes a restore-info state carrying .ledger.
        do {
            var estimatedBirthdayState = WalletBirthday.State.initial
            estimatedBirthdayState.hardwareWalletVendor = .ledger
            var initialState = ConnectHWWalletCoordFlow.State()
            initialState.path.append(.ledgerDeviceReady(AddLedgerHWWallet.State.initial))
            initialState.path.append(.estimatedBirthday(estimatedBirthdayState))
            let store = makeStore(initialState: initialState)
            let estimatedId = store.state.path.ids.last!

            store.send(.path(.element(id: estimatedId, action: .estimatedBirthday(.restoreTapped))))

            #expect(store.state.path.count == 3)
            if case .restoreInfo(let restoreInfoState) = store.state.path.last {
                #expect(restoreInfoState.hardwareWalletVendor == .ledger)
            } else {
                Issue.record("expected .restoreInfo to be pushed")
            }
        }

        // .estimatedBirthday(.enterManuallyTapped), from an .estimatedBirthday element that
        // already carries .ledger, pushes a birthday state carrying .ledger.
        do {
            var estimatedBirthdayState = WalletBirthday.State.initial
            estimatedBirthdayState.hardwareWalletVendor = .ledger
            var initialState = ConnectHWWalletCoordFlow.State()
            initialState.path.append(.ledgerDeviceReady(AddLedgerHWWallet.State.initial))
            initialState.path.append(.estimatedBirthday(estimatedBirthdayState))
            let store = makeStore(initialState: initialState)
            let estimatedId = store.state.path.ids.last!

            store.send(.path(.element(id: estimatedId, action: .estimatedBirthday(.enterManuallyTapped))))

            #expect(store.state.path.count == 3)
            if case .walletBirthday(let birthdayState) = store.state.path.last {
                #expect(birthdayState.hardwareWalletVendor == .ledger)
            } else {
                Issue.record("expected .walletBirthday to be pushed")
            }
        }
    }

    // MARK: - Helpers

    private func makeStore(
        initialState: ConnectHWWalletCoordFlow.State = ConnectHWWalletCoordFlow.State(),
        withDependencies extra: (@Sendable (inout DependencyValues) -> Void)? = nil
    ) -> StoreOf<ConnectHWWalletCoordFlow> {
        Store(initialState: initialState) {
            ConnectHWWalletCoordFlow()
        } withDependencies: {
            $0.walletStorage = .noOp
            // LedgerClient has no test/preview value (Phase 0 only registered `liveValue`), so
            // every path that can reach the element's disconnect-on-exit calls
            // (forgetThisDeviceTapped/backToHomeTapped/closeTapped/accountImportSucceeded) needs
            // an explicit override or it trips "has no test implementation".
            $0.ledgerClient = .noOp
            extra?(&$0)
        }
    }

    private func isDevicePicker(_ element: ConnectHWWalletCoordFlow.Path.State?) -> Bool {
        if case .ledgerDevicePicker = element { return true }
        return false
    }

    private func isApproveOnDevice(_ element: ConnectHWWalletCoordFlow.Path.State?) -> Bool {
        if case .ledgerApproveOnDevice = element { return true }
        return false
    }

    private func isConnected(_ element: ConnectHWWalletCoordFlow.Path.State?) -> Bool {
        if case .ledgerConnected = element { return true }
        return false
    }

    /// Mirrors AddLedgerHWWalletTests' own private fixture. `ufvk` defaults to `nil`, matching an
    /// account that was never asked to carry a viewing key.
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

    /// A non-Ledger fixture (`WalletAccount.vendor == .keystone`) for tests that need an
    /// unrelated account on `walletAccounts` without tripping the "wallet holds at most one
    /// Ledger account" wrong-Ledger guard (MOB-2020, Android d1506d0d).
    private static func keystoneWalletAccount(idByte: UInt8, ufvk: String? = nil) -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
            name: "Keystone",
            keySource: Account.keystoneKeySource,
            seedFingerprint: nil,
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: ufvk.map { UnifiedFullViewingKey(validatedEncoding: $0) },
            uivk: nil
        ))
    }

    /// `LedgerAccountBinding`'s device identity is `tpk0-` plus 64 lowercase hex digits, validated
    /// through the linked FFI -- same fixture shape as LedgerSessionTests/AddLedgerHWWalletTests.
    /// `ufvk` defaults to the same sentinel every other fixture in this file used before the
    /// pre-import collision check existed; the collision tests pass their own to control the match.
    private static func makePairingFixture(ufvk: String = "utest1fixture") throws -> LedgerPairing {
        LedgerPairing(
            ufvk: ufvk,
            binding: LedgerAccountBinding(
                deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-" + String(repeating: "a", count: 64)),
                zip32AccountIndex: Zip32AccountIndex(0)
            ),
            appVersion: "3.9.3"
        )
    }
}
