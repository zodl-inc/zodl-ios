//
//  AddLedgerHWWalletCoordFlowTests.swift
//  zodlTests
//
//  Mirrors AddKeystoneHWWalletCoordFlowTests: navigation pushes/pops driven by the element
//  screens' own actions, the failure sheet (show / suppress-behind-success / clear a pending
//  RestoreInfo spinner), and a connection-lost pairing failure popping back to the device
//  picker (Features/CoordFlows/AddLedgerHWWalletCoordFlow*.swift).
//
//  AddLedgerHWWalletCoordFlow.State is not Equatable (it contains a non-Equatable StackState),
//  so these tests drive a plain Store and read state directly after sending actions -- the same
//  approach AddKeystoneHWWalletCoordFlowTests uses.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct AddLedgerHWWalletCoordFlowTests {

    // MARK: - Self: connectTapped

    @Test func connectTappedPushesDevicePicker() async {
        let store = makeStore()

        store.send(.addLedgerHWWallet(.connectTapped))

        #expect(store.state.path.count == 1)
        #expect(isDevicePicker(store.state.path.first))
    }

    // MARK: - Device Picker

    @Test func deviceConnectedPushesPairingAndStartsPairing() async throws {
        var initialState = AddLedgerHWWalletCoordFlow.State()
        initialState.path.append(.devicePicker(AddLedgerHWWallet.State.initial))
        let pairCallCount = LockIsolated(0)
        // A device refusal (not a transport failure) so this test's own pairAccount call can't
        // also trigger the connection-lost pop-to-picker arm covered separately below.
        let store = makeStore(initialState: initialState) {
            $0.ledgerClient.pairAccount = { _ in
                pairCallCount.withValue { $0 += 1 }
                throw ZcashError.ledgerUserRejected
            }
        }
        let devicePickerId = store.state.path.ids.first!

        store.send(.path(.element(id: devicePickerId, action: .devicePicker(.deviceConnected))))

        for _ in 0..<50 {
            if pairCallCount.value > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(pairCallCount.value == 1)
        #expect(store.state.path.count == 2)
        #expect(isPairing(store.state.path.last))
    }

    // MARK: - Pairing

    @Test func pairingSucceededPushesAccountCarryingThePairing() async throws {
        var initialState = AddLedgerHWWalletCoordFlow.State()
        initialState.path.append(.pairing(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!
        let fixture = try Self.makePairingFixture()

        store.send(.path(.element(id: id, action: .pairing(.pairingSucceeded(fixture)))))

        #expect(store.state.path.count == 2)
        if case .account(let accountState) = store.state.path.last {
            #expect(accountState.pairing == fixture)
        } else {
            Issue.record("expected .account to be pushed carrying the pairing")
        }
    }

    @Test func pairingFailureWithConnectionLostPopsBackToDevicePicker() async throws {
        var initialState = AddLedgerHWWalletCoordFlow.State()
        initialState.path.append(.devicePicker(AddLedgerHWWallet.State.initial))
        initialState.path.append(.pairing(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let pairingId = store.state.path.ids.last!

        store.send(.path(.element(id: pairingId, action: .pairing(.pairingFailed(message: "lost", connectionLost: true)))))

        // The pop is deferred one cycle past `.connectionLostWhilePairing` (see the coordinator);
        // poll until it lands or give up.
        for _ in 0..<50 {
            if store.state.path.count == 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(store.state.path.count == 1)
        #expect(isDevicePicker(store.state.path.first))
    }

    @Test func pairingFailureWithoutConnectionLostStaysOnPairing() async {
        var initialState = AddLedgerHWWalletCoordFlow.State()
        initialState.path.append(.devicePicker(AddLedgerHWWallet.State.initial))
        initialState.path.append(.pairing(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let pairingId = store.state.path.ids.last!

        store.send(.path(.element(id: pairingId, action: .pairing(.pairingFailed(message: "refused", connectionLost: false)))))

        #expect(store.state.path.count == 2)
        #expect(isPairing(store.state.path.last))
    }

    // MARK: - Account

    @Test func nextTappedPushesDeviceReadyCarryingTheAccountState() async {
        var accountState = AddLedgerHWWallet.State.initial
        accountState.isAccountSelected = true
        var initialState = AddLedgerHWWalletCoordFlow.State()
        initialState.path.append(.account(accountState))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .account(.nextTapped))))

        #expect(store.state.path.count == 2)
        if case .deviceReady(let deviceReadyState) = store.state.path.last {
            #expect(deviceReadyState.isAccountSelected == true)
        } else {
            Issue.record("expected .deviceReady to be pushed carrying the account state")
        }
    }

    // MARK: - Device Ready: accountImportSucceeded

    @Test func accountImportSucceededPushesConnectedScreen() async {
        var initialState = AddLedgerHWWalletCoordFlow.State()
        initialState.path.append(.deviceReady(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .deviceReady(.accountImportSucceeded))))

        #expect(store.state.path.count == 2)
        #expect(isConnected(store.state.path.last))
    }

    // MARK: - Device Ready: accountImportFailed

    @Test func accountImportFailedShowsFailureSheet() async {
        var initialState = AddLedgerHWWalletCoordFlow.State()
        initialState.path.append(.deviceReady(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .deviceReady(.accountImportFailed("boom")))))

        #expect(store.state.isFailureSheetPresented == true)
        #expect(store.state.errMsg == "boom")
    }

    @Test func accountImportFailedAfterSuccessScreenIsIgnored() async {
        var initialState = AddLedgerHWWalletCoordFlow.State()
        initialState.path.append(.deviceReady(AddLedgerHWWallet.State.initial))
        initialState.path.append(.connected(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .deviceReady(.accountImportFailed("duplicate")))))

        #expect(store.state.isFailureSheetPresented == false)
        #expect(store.state.errMsg.isEmpty)
    }

    @Test func accountImportFailedAfterSuccessScreenStillClearsRestoreInfoProcessing() async {
        // Even when the failure sheet is suppressed (success screen on the stack), any
        // RestoreInfo element must not be left with a stuck spinner.
        var restoreInfoState = RestoreInfo.State.initial
        restoreInfoState.isKeystoneFlow = true
        restoreInfoState.isProcessing = true
        var initialState = AddLedgerHWWalletCoordFlow.State()
        initialState.path.append(.deviceReady(AddLedgerHWWallet.State.initial))
        initialState.path.append(.restoreInfo(restoreInfoState))
        initialState.path.append(.connected(AddLedgerHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .deviceReady(.accountImportFailed("duplicate")))))

        #expect(store.state.isFailureSheetPresented == false)
        #expect(store.state.errMsg.isEmpty)
        let restoreInfoIsProcessing = store.state.path.compactMap {
            if case .restoreInfo(let element) = $0 { element.isProcessing } else { nil }
        }.first
        #expect(restoreInfoIsProcessing == false)
    }

    // MARK: - cancelFailureTapped

    @Test func cancelFailureTappedHidesSheet() async {
        var initialState = AddLedgerHWWalletCoordFlow.State()
        initialState.isFailureSheetPresented = true
        let store = makeStore(initialState: initialState)

        store.send(.cancelFailureTapped)

        #expect(store.state.isFailureSheetPresented == false)
    }

    // MARK: - contactSupportTapped

    @Test func contactSupportTappedWithMailCapabilitySetsSupportData() async {
        var initialState = AddLedgerHWWalletCoordFlow.State()
        initialState.isFailureSheetPresented = true
        initialState.canSendMail = true
        initialState.errMsg = "ZLEDG0002: some ledger error"
        let store = makeStore(initialState: initialState)

        store.send(.contactSupportTapped)

        #expect(store.state.isFailureSheetPresented == false)
        #expect(store.state.supportData != nil)
    }

    @Test func contactSupportTappedWithoutMailSetsMessageToBeShared() async {
        var initialState = AddLedgerHWWalletCoordFlow.State()
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
        var initialState = AddLedgerHWWalletCoordFlow.State()
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
        var initialState = AddLedgerHWWalletCoordFlow.State()
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
        var initialState = AddLedgerHWWalletCoordFlow.State()
        initialState.path.append(.deviceReady(deviceReadyState))

        let importCount = LockIsolated(0)
        let uuid = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))
        let store = Store(initialState: initialState) {
            AddLedgerHWWalletCoordFlow()
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

        store.send(.path(.element(id: id, action: .deviceReady(.unlockTapped(nil)))))

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
        initialState: AddLedgerHWWalletCoordFlow.State = AddLedgerHWWalletCoordFlow.State(),
        withDependencies extra: (@Sendable (inout DependencyValues) -> Void)? = nil
    ) -> StoreOf<AddLedgerHWWalletCoordFlow> {
        Store(initialState: initialState) {
            AddLedgerHWWalletCoordFlow()
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

    private func isDevicePicker(_ element: AddLedgerHWWalletCoordFlow.Path.State?) -> Bool {
        if case .devicePicker = element { return true }
        return false
    }

    private func isPairing(_ element: AddLedgerHWWalletCoordFlow.Path.State?) -> Bool {
        if case .pairing = element { return true }
        return false
    }

    private func isConnected(_ element: AddLedgerHWWalletCoordFlow.Path.State?) -> Bool {
        if case .connected = element { return true }
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
