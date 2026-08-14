//
//  AddKeystoneHWWalletTests.swift
//  zodlTests
//
//  More reducers — covers AddKeystoneHWWallet hex parsing, UI toggles, the unlock guard,
//  imported-account selection and derived display state
//  (Features/AddKeystoneHWWallet/AddHWWalletStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import KeystoneSDK
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct AddKeystoneHWWalletTests {
    // MARK: - hexStringToBytes

    @Test func hexStringToBytesParsesValidEvenLengthHex() {
        #expect(AddKeystoneHWWallet.hexStringToBytes("00ff10") == [0x00, 0xff, 0x10])
        #expect(AddKeystoneHWWallet.hexStringToBytes("") == [])
    }

    @Test func hexStringToBytesRejectsOddLengthAndInvalidCharacters() {
        #expect(AddKeystoneHWWallet.hexStringToBytes("abc") == nil)  // odd length
        #expect(AddKeystoneHWWallet.hexStringToBytes("zz") == nil)   // not hex digits
    }

    // MARK: - UI toggles

    @MainActor @Test func helpSheetRequestedTogglesSheet() async {
        let store = TestStore(initialState: AddKeystoneHWWallet.State()) { AddKeystoneHWWallet() }

        await store.send(.helpSheetRequested) { $0.isHelpSheetPresented = true }
        await store.send(.helpSheetRequested) { $0.isHelpSheetPresented = false }
    }

    @MainActor @Test func accountTappedTogglesSelection() async {
        let store = TestStore(initialState: AddKeystoneHWWallet.State()) { AddKeystoneHWWallet() }

        await store.send(.accountTapped) { $0.isKSAccountSelected = true }
        await store.send(.accountTapped) { $0.isKSAccountSelected = false }
    }

    @MainActor @Test func viewTutorialTappedOpensInAppBrowser() async {
        let store = TestStore(initialState: AddKeystoneHWWallet.State()) { AddKeystoneHWWallet() }

        await store.send(.viewTutorialTapped) { $0.isInAppBrowserOn = true }
    }

    // MARK: - readyToScan / unlock guard

    @MainActor @Test func readyToScanTappedResetsQRDecoder() async {
        let resetCalled = LockIsolated(false)
        let store = TestStore(initialState: AddKeystoneHWWallet.State()) {
            AddKeystoneHWWallet()
        } withDependencies: {
            $0.keystoneHandler.resetQRDecoder = { resetCalled.setValue(true) }
        }

        await store.send(.readyToScanTapped)

        #expect(resetCalled.value)
    }

    @MainActor @Test func unlockTappedWithoutScannedAccountsIsNoOp() async {
        // No zcashAccounts have been scanned yet, so there is nothing to import.
        let store = TestStore(initialState: AddKeystoneHWWallet.State()) { AddKeystoneHWWallet() }

        await store.send(.unlockTapped(nil))
    }

    // MARK: - loadedWalletAccounts

    @MainActor @Test func loadedWalletAccountsStoresAllAndSelectsMatchingUUID() async {
        let first = walletAccount(idByte: 0x01)
        let second = walletAccount(idByte: 0x02)
        var state = AddKeystoneHWWallet.State()
        state.$walletAccounts.withLock { $0 = [] }
        state.$selectedWalletAccount.withLock { $0 = nil }
        let store = TestStore(initialState: state) { AddKeystoneHWWallet() }

        await store.send(.loadedWalletAccounts([first, second], second.id)) {
            $0.$walletAccounts.withLock { $0 = [first, second] }
            $0.$selectedWalletAccount.withLock { $0 = second }
        }
    }

    // MARK: - accountImportFailed

    @MainActor @Test func accountImportFailedIsNoOpOnElementStore() async {
        // The element store just passes the error string along; the coordinator
        // owns the failure-sheet state and handles the visual side.
        let store = TestStore(initialState: AddKeystoneHWWallet.State()) { AddKeystoneHWWallet() }
        await store.send(.accountImportFailed("ZRUST0067: some rust error"))
    }

    @MainActor @Test func unlockTappedSDKThrowSendsAccountImportFailed() async {
        var state = AddKeystoneHWWallet.State()
        state.zcashAccounts = ZcashAccounts.testFixture()
        let store = TestStore(initialState: state) {
            AddKeystoneHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer = .mocked(importAccount: { _, _, _, _, _, _, _ in
                throw TestError.importFailed
            })
        }
        store.exhaustivity = .off
        await store.send(.unlockTapped(nil))
        await store.receive(\.accountImportFailed)
    }

    @MainActor @Test func unlockTappedNilImportResultSendsAccountImportFailed() async {
        // The interface types importAccount as AccountUUID?; a nil result must
        // clear isImportingAccount via accountImportFailed, not hang the UI.
        var state = AddKeystoneHWWallet.State()
        state.zcashAccounts = ZcashAccounts.testFixture()
        let store = TestStore(initialState: state) {
            AddKeystoneHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer = .mocked(importAccount: { _, _, _, _, _, _, _ in nil })
        }
        store.exhaustivity = .off
        await store.send(.unlockTapped(nil))
        await store.receive(\.accountImportFailed)
    }

    @MainActor @Test func unlockTappedIgnoresRetapsWhileImportInFlight() async {
        var state = AddKeystoneHWWallet.State()
        state.zcashAccounts = ZcashAccounts.testFixture()
        let importCount = LockIsolated(0)
        // The mock parks on this instead of a real-time sleep, and the test releases it only
        // after the re-tap below has already been sent -- so "while import is in flight" holds
        // by construction, not by racing a timer against however busy the main actor is.
        let (releaseImport, releaseImportContinuation) = AsyncStream<Void>.makeStream()
        let store = TestStore(initialState: state) {
            AddKeystoneHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer = .mocked(
                importAccount: { _, _, _, _, _, _, _ in
                    importCount.withValue { $0 += 1 }
                    for await _ in releaseImport { break }
                    return AccountUUID(id: [UInt8](repeating: 0x01, count: 16))
                },
                walletAccounts: { [] }
            )
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

    @MainActor @Test func accountImportFailedClearsImportingFlag() async {
        var state = AddKeystoneHWWallet.State()
        state.isImportingAccount = true
        let store = TestStore(initialState: state) { AddKeystoneHWWallet() }

        await store.send(.accountImportFailed("boom")) { $0.isImportingAccount = false }
    }

    @MainActor @Test func accountImportedWalletLoadThrowSendsAccountImportFailed() async {
        let uuid = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))
        let store = TestStore(initialState: AddKeystoneHWWallet.State()) {
            AddKeystoneHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer.walletAccounts = { throw TestError.loadFailed }
        }
        store.exhaustivity = .off
        await store.send(.accountImported(uuid))
        await store.receive(\.accountImportFailed)
    }

    // MARK: - Derived state

    @Test func keystoneNameDefaultsToKeystoneWalletWithoutScannedAccount() {
        let state = AddKeystoneHWWallet.State()
        #expect(state.keystoneName == String(localizable: .keystoneWallet))
    }

    @Test func inAppBrowserURLPointsAtTutorialVideo() {
        let state = AddKeystoneHWWallet.State()
        #expect(state.inAppBrowserURL.contains("youtube.com"))
    }

    // MARK: - Helpers

    private enum TestError: Error { case importFailed, loadFailed }

    private func walletAccount(idByte: UInt8) -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
            name: "Keystone",
            keySource: String(localizable: .accountsKeystone).lowercased(),
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        ))
    }
}
