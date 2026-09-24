//
//  ConnectHWWalletCoordFlowKeystoneTests.swift
//  zodlTests
//
//  Covers the coordinator-level error-handling state added for #1920, now exercised through the
//  merged `ConnectHWWalletCoordFlow` (MOB-2020 UI round 2 -- the flow's root is the vendor
//  chooser, and the Keystone instructions screen that used to be the old
//  AddKeystoneHWWalletCoordFlow's own root is a `Path` element instead):
//  - accountImportFailed bubbles up from a path element and shows the failure sheet
//  - cancelFailureTapped hides the sheet and exits the flow
//  - contactSupportTapped routes to mail or share depending on device capability
//  - sendSupportMailFinished / shareFinished clear their respective state
//  (Features/CoordFlows/ConnectHWWalletCoordFlow*.swift)
//
//  ConnectHWWalletCoordFlow.State is not Equatable (it contains a non-Equatable StackState), so
//  these tests drive a plain Store and read state directly after sending actions — the same
//  approach used by ScanCoordFlowZip321Tests. Initial state is set up before Store creation
//  (never via store.state mutation, which is get-only on a plain Store).
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import KeystoneSDK
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) @MainActor struct ConnectHWWalletCoordFlowKeystoneTests {

    // MARK: - accountImportFailed from keystoneDeviceReady

    @Test func accountImportFailedShowsFailureSheet() async {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.keystoneDeviceReady(AddKeystoneHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .keystoneDeviceReady(.accountImportFailed("boom")))))

        #expect(store.state.isFailureSheetPresented == true)
        #expect(store.state.errMsg == "boom")
    }

    @Test func accountImportFailedAfterSuccessScreenIsIgnored() async {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.keystoneDeviceReady(AddKeystoneHWWallet.State.initial))
        initialState.path.append(.keystoneConnected(AddKeystoneHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .keystoneDeviceReady(.accountImportFailed("duplicate")))))

        #expect(store.state.isFailureSheetPresented == false)
        #expect(store.state.errMsg.isEmpty)
    }

    @Test func accountImportFailedAfterSuccessScreenStillClearsRestoreInfoProcessing() async {
        // Even when the failure sheet is suppressed (success screen on the stack),
        // any RestoreInfo element must not be left with a stuck spinner.
        var restoreInfoState = RestoreInfo.State.initial
        restoreInfoState.isKeystoneFlow = true
        restoreInfoState.isProcessing = true
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.keystoneDeviceReady(AddKeystoneHWWallet.State.initial))
        initialState.path.append(.restoreInfo(restoreInfoState))
        initialState.path.append(.keystoneConnected(AddKeystoneHWWallet.State.initial))
        let store = makeStore(initialState: initialState)
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .keystoneDeviceReady(.accountImportFailed("duplicate")))))

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
        initialState.errMsg = "ZRUST0067: rust error"
        let store = makeStore(initialState: initialState)

        store.send(.contactSupportTapped)

        #expect(store.state.isFailureSheetPresented == false)
        #expect(store.state.supportData != nil)
    }

    @Test func contactSupportTappedWithoutMailSetsMessageToBeShared() async {
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.isFailureSheetPresented = true
        initialState.canSendMail = false
        initialState.errMsg = "ZRUST0067: rust error"
        let store = makeStore(initialState: initialState)

        store.send(.contactSupportTapped)

        #expect(store.state.isFailureSheetPresented == false)
        #expect(store.state.messageToBeShared != nil)
    }

    // MARK: - Mail / share cleanup

    @Test func sendSupportMailFinishedClearsSupportData() async {
        var initialState = ConnectHWWalletCoordFlow.State()
        // generate() reads walletStorage; this call runs in test code, outside
        // the store's dependency scope, so it needs its own override.
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

    // MARK: - Successful import (repro: failure sheet must NOT show on success)

    @Test func successfulImportPushesSuccessScreenWithoutFailureSheet() async throws {
        var elementState = AddKeystoneHWWallet.State.initial
        elementState.zcashAccounts = ZcashAccounts.testFixture()
        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.keystoneDeviceReady(elementState))

        let importCount = LockIsolated(0)
        let uuid = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))
        let store = Store(initialState: initialState) {
            ConnectHWWalletCoordFlow()
        } withDependencies: {
            $0.audioServices.systemSoundVibrate = { }
            $0.sdkSynchronizer = .mocked(
                importAccount: { _, _, _, _, _, _, _ in
                    importCount.withValue { $0 += 1 }
                    return uuid
                },
                walletAccounts: { [] }
            )
        }
        let id = store.state.path.ids.first!

        store.send(.path(.element(id: id, action: .keystoneDeviceReady(.unlockTapped(nil)))))

        // Effects chain asynchronously (unlockTapped -> accountImported -> accountImportSucceeded);
        // poll until the success screen lands or we give up.
        for _ in 0..<50 {
            if store.state.path.contains(where: { if case .keystoneConnected = $0 { true } else { false } }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(importCount.value == 1)
        #expect(store.state.path.contains(where: { if case .keystoneConnected = $0 { true } else { false } }))
        #expect(store.state.isFailureSheetPresented == false)
        #expect(store.state.errMsg.isEmpty)
    }

    // MARK: - hardwareWalletVendor (MOB-2020: Keystone-branding fix)

    @Test func keystoneBirthdayAndRestoreScreensKeepTheKeystoneVendor() async {
        // .keystoneDeviceReady(.setBirthdayTapped) pushes a birthday state staying .keystone.
        do {
            var initialState = ConnectHWWalletCoordFlow.State()
            initialState.path.append(.addKeystoneHWWallet(AddKeystoneHWWallet.State.initial))
            initialState.path.append(.keystoneDeviceReady(AddKeystoneHWWallet.State.initial))
            let store = makeStore(initialState: initialState)
            let deviceReadyId = store.state.path.ids.last!

            store.send(.path(.element(id: deviceReadyId, action: .keystoneDeviceReady(.setBirthdayTapped))))

            #expect(store.state.path.count == 3)
            if case .estimateBirthdaysDate(let birthdayState) = store.state.path.last {
                #expect(birthdayState.hardwareWalletVendor == .keystone)
            } else {
                Issue.record("expected .estimateBirthdaysDate to be pushed")
            }
        }

        // .estimateBirthdaysDate(.enterManuallyTapped) pushes a manual birthday state staying .keystone.
        do {
            var initialState = ConnectHWWalletCoordFlow.State()
            initialState.path.append(.keystoneDeviceReady(AddKeystoneHWWallet.State.initial))
            initialState.path.append(.estimateBirthdaysDate(WalletBirthday.State.initial))
            let store = makeStore(initialState: initialState)
            let estimateId = store.state.path.ids.last!

            store.send(.path(.element(id: estimateId, action: .estimateBirthdaysDate(.enterManuallyTapped))))

            #expect(store.state.path.count == 3)
            if case .walletBirthday(let birthdayState) = store.state.path.last {
                #expect(birthdayState.hardwareWalletVendor == .keystone)
            } else {
                Issue.record("expected .walletBirthday to be pushed")
            }
        }

        // .walletBirthday(.restoreTapped) pushes a restore-info state staying .keystone.
        do {
            var initialState = ConnectHWWalletCoordFlow.State()
            initialState.path.append(.keystoneDeviceReady(AddKeystoneHWWallet.State.initial))
            initialState.path.append(.walletBirthday(WalletBirthday.State.initial))
            let store = makeStore(initialState: initialState)
            let walletBirthdayId = store.state.path.ids.last!

            store.send(.path(.element(id: walletBirthdayId, action: .walletBirthday(.restoreTapped))))

            #expect(store.state.path.count == 3)
            if case .restoreInfo(let restoreInfoState) = store.state.path.last {
                #expect(restoreInfoState.hardwareWalletVendor == .keystone)
            } else {
                Issue.record("expected .restoreInfo to be pushed")
            }
        }

        // .estimatedBirthday(.restoreTapped) pushes a restore-info state staying .keystone.
        do {
            var initialState = ConnectHWWalletCoordFlow.State()
            initialState.path.append(.keystoneDeviceReady(AddKeystoneHWWallet.State.initial))
            initialState.path.append(.estimatedBirthday(WalletBirthday.State.initial))
            let store = makeStore(initialState: initialState)
            let estimatedId = store.state.path.ids.last!

            store.send(.path(.element(id: estimatedId, action: .estimatedBirthday(.restoreTapped))))

            #expect(store.state.path.count == 3)
            if case .restoreInfo(let restoreInfoState) = store.state.path.last {
                #expect(restoreInfoState.hardwareWalletVendor == .keystone)
            } else {
                Issue.record("expected .restoreInfo to be pushed")
            }
        }

        // .estimatedBirthday(.enterManuallyTapped) pushes a birthday state staying .keystone.
        do {
            var initialState = ConnectHWWalletCoordFlow.State()
            initialState.path.append(.keystoneDeviceReady(AddKeystoneHWWallet.State.initial))
            initialState.path.append(.estimatedBirthday(WalletBirthday.State.initial))
            let store = makeStore(initialState: initialState)
            let estimatedId = store.state.path.ids.last!

            store.send(.path(.element(id: estimatedId, action: .estimatedBirthday(.enterManuallyTapped))))

            #expect(store.state.path.count == 3)
            if case .walletBirthday(let birthdayState) = store.state.path.last {
                #expect(birthdayState.hardwareWalletVendor == .keystone)
            } else {
                Issue.record("expected .walletBirthday to be pushed")
            }
        }
    }

    // MARK: - Helpers

    private func makeStore(
        initialState: ConnectHWWalletCoordFlow.State = ConnectHWWalletCoordFlow.State()
    ) -> StoreOf<ConnectHWWalletCoordFlow> {
        Store(initialState: initialState) {
            ConnectHWWalletCoordFlow()
        } withDependencies: {
            $0.audioServices.systemSoundVibrate = { }
            // SupportDataGenerator.generate (contactSupportTapped) reads walletStorage.
            $0.walletStorage = .noOp
        }
    }
}
