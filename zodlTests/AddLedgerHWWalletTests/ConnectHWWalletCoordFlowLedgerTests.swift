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

    // MARK: - cancelFailureTapped

    @Test func cancelFailureTappedHidesSheet() async {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.isFailureSheetPresented = true
        let store = makeStore(initialState: initialState)

        store.send(.cancelFailureTapped)

        #expect(store.state.isFailureSheetPresented == false)
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

    /// `LedgerAccountBinding`'s device identity is `tpk0-` plus 64 lowercase hex digits, validated
    /// through the linked FFI -- same fixture shape as LedgerSessionTests/AddLedgerHWWalletTests.
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
}
