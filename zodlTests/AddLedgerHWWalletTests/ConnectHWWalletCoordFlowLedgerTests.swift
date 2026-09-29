//
//  ConnectHWWalletCoordFlowLedgerTests.swift
//  zodlTests
//
//  Mirrors ConnectHWWalletCoordFlowKeystoneTests: navigation pushes/pops driven by the element
//  screens' own actions, and the failure sheet (show / suppress-behind-success / clear a
//  pending RestoreInfo spinner), now exercised through the merged `ConnectHWWalletCoordFlow`
//  (MOB-2020 UI round 2 -- the flow's root is the vendor chooser, and the Ledger instructions
//  screen that used to be the old AddLedgerHWWalletCoordFlow's own root, along with the device
//  picker/account/device-ready/connected screens, are `Path` elements with the `ledger`-prefixed
//  case names). The device picker finds, selects, connects and pairs the Ledger on its own
//  screen -- a connection-lost failure there just rescans in place, so it has no coordinator-level
//  navigation of its own to cover here; see AddLedgerHWWalletTests for that behavior
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

    @Test func pairingSucceededOnThePickerPushesTheAccountScreen() async throws {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.ledgerDevicePicker(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!
        let fixture = try Self.makePairingFixture()

        store.send(.path(.element(id: id, action: .ledgerDevicePicker(.pairingSucceeded(fixture)))))

        #expect(store.state.path.count == 2)
        if case .ledgerAccount(let accountState) = store.state.path.last {
            #expect(accountState.pairing == fixture)
        } else {
            Issue.record("expected .ledgerAccount to be pushed carrying the pairing")
        }
    }

    @Test func pairingANewLedgerStillShowsItsAccount() async throws {
        var devicePickerState = AddLedgerHWWallet.State.initial
        // No account carries the pairing's UFVK, so the pre-import check must let this through.
        devicePickerState.$walletAccounts.withLock { $0 = [Self.walletAccount(idByte: 0x0f, ufvk: "uview1someotherfixture")] }
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerDevicePicker(devicePickerState))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.last!
        let fixture = try Self.makePairingFixture(ufvk: "uview1ledgerpairingfixture")

        store.send(.path(.element(id: id, action: .ledgerDevicePicker(.pairingSucceeded(fixture)))))

        #expect(store.state.path.count == 3)
        if case .ledgerAccount(let accountState) = store.state.path.last {
            #expect(accountState.pairing == fixture)
        } else {
            Issue.record("expected .ledgerAccount to be pushed carrying the pairing")
        }
        #expect(store.state.isAccountAlreadyAddedSheetPresented == false)
        #expect(store.state.alreadyAddedAccount == nil)
    }

    @Test func pairingALedgerAlreadyInTheWalletRaisesAccountAlreadyAddedOnThePicker() async throws {
        let matchingUFVK = "uview1ledgerpairingfixture"
        let existingAccount = Self.walletAccount(idByte: 0x0f, ufvk: matchingUFVK)
        var devicePickerState = AddLedgerHWWallet.State.initial
        devicePickerState.$walletAccounts.withLock { $0 = [existingAccount] }
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerDevicePicker(devicePickerState))
        let fixture = try Self.makePairingFixture(ufvk: matchingUFVK)
        // MOB-2020 (Rebound): this account already has a binding, so the picker still raises
        // "Account Already Added" -- `.noOp`'s own `exportLedgerBinding` throws
        // `uninitializedLedgerBinding` by default, which would otherwise take the Rebound branch
        // (see `pairingAnUnboundExistingLedgerAccountReboundsItAndLeavesTheFlow` below).
        let store = makeStore(initialState: initialState) {
            $0.walletStorage.exportLedgerBinding = { _ in fixture.binding }
        }
        let id = store.state.path.ids.last!

        store.send(.path(.element(id: id, action: .ledgerDevicePicker(.pairingSucceeded(fixture)))))

        // The collision check (and, for an unbound match, the rebind) now runs in an effect --
        // poll for it to land instead of asserting synchronously right after `send`.
        for _ in 0..<50 {
            if store.state.isAccountAlreadyAddedSheetPresented { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.state.alreadyAddedAccount == existingAccount)
        #expect(store.state.isAccountAlreadyAddedSheetPresented == true)
        // The path still ends at the picker -- the collision arm pushes nothing.
        #expect(store.state.path.count == 2)
        #expect(isDevicePicker(store.state.path.last))
    }

    // MOB-2020 (Android b013b7c2, Rebound): an unbound match can never sign again, so pairing
    // stores the new binding onto it instead of dead-ending on "Account Already Added".
    @Test func pairingAnUnboundExistingLedgerAccountReboundsItAndLeavesTheFlow() async throws {
        let matchingUFVK = "uview1ledgerpairingfixture"
        let existingAccount = Self.walletAccount(idByte: 0x0f, ufvk: matchingUFVK)
        var devicePickerState = AddLedgerHWWallet.State.initial
        devicePickerState.$walletAccounts.withLock { $0 = [existingAccount] }
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerDevicePicker(devicePickerState))
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

        store.send(.path(.element(id: id, action: .ledgerDevicePicker(.pairingSucceeded(fixture)))))

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
    @Test func aFailedRebindStillRaisesAccountAlreadyAddedOnThePicker() async throws {
        struct BindingWriteFailure: Error {}
        let matchingUFVK = "uview1ledgerpairingfixture"
        let existingAccount = Self.walletAccount(idByte: 0x0f, ufvk: matchingUFVK)
        var devicePickerState = AddLedgerHWWallet.State.initial
        devicePickerState.$walletAccounts.withLock { $0 = [existingAccount] }
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.path.append(.ledgerDevicePicker(devicePickerState))
        let fixture = try Self.makePairingFixture(ufvk: matchingUFVK)
        // `exportLedgerBinding` keeps `.noOp`'s unbound default; only the store itself fails.
        let store = makeStore(initialState: initialState) {
            $0.walletStorage.importLedgerBinding = { _, _ in throw BindingWriteFailure() }
        }
        let id = store.state.path.ids.last!

        store.send(.path(.element(id: id, action: .ledgerDevicePicker(.pairingSucceeded(fixture)))))

        for _ in 0..<50 {
            if store.state.isAccountAlreadyAddedSheetPresented { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.state.alreadyAddedAccount == existingAccount)
        #expect(store.state.isAccountAlreadyAddedSheetPresented == true)
        #expect(store.state.path.count == 2)
        #expect(isDevicePicker(store.state.path.last))
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
