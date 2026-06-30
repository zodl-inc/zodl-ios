//
//  DisconnectHWWalletTests.swift
//  zodlTests
//
//  More tests — hardware wallet. Covers DisconnectHWWallet state machine + support routing
//  (Features/DisconnectHWWallet/DisconnectHWWalletStore.swift).
//

import Testing
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct DisconnectHWWalletTests {
    @MainActor @Test func disconnectTappedShowsSheetAndProcesses() async {
        let store = TestStore(initialState: DisconnectHWWallet.State()) { DisconnectHWWallet() }
        await store.send(.disconnectTapped) {
            $0.isSheetUp = true
            $0.isProcessing = true
        }
    }

    @MainActor @Test func disconnectFailedShowsFailureSheet() async {
        let store = TestStore(initialState: DisconnectHWWallet.State(isProcessing: true)) { DisconnectHWWallet() }
        await store.send(.disconnectFailed("boom")) {
            $0.isProcessing = false
            $0.isFailureSheetUp = true
            $0.errMsg = "boom"
        }
    }

    @MainActor @Test func disconnectFinishedStopsProcessing() async {
        let store = TestStore(initialState: DisconnectHWWallet.State(isProcessing: true)) { DisconnectHWWallet() }
        await store.send(.disconnectFinished) { $0.isProcessing = false }
    }

    @MainActor @Test func dismissSheetResetsState() async {
        var state = DisconnectHWWallet.State(isProcessing: true)
        state.isSheetUp = true
        let store = TestStore(initialState: state) { DisconnectHWWallet() }
        await store.send(.dismissSheet) {
            $0.isSheetUp = false
            $0.isProcessing = false
        }
    }

    @MainActor @Test func disconnectConfirmedWithoutKeystoneIsNoOp() async {
        var state = DisconnectHWWallet.State()
        state.isSheetUp = true
        state.$walletAccounts.withLock { $0 = [] }
        let store = TestStore(initialState: state) { DisconnectHWWallet() }
        await store.send(.disconnectConfirmed) { $0.isSheetUp = false }
    }

    @MainActor @Test func disconnectConfirmedWithKeystoneDeletesAccount() async {
        var state = DisconnectHWWallet.State(isProcessing: true)
        state.isSheetUp = true
        state.$walletAccounts.withLock { $0 = [keystoneAccount()] }
        let store = TestStore(initialState: state) {
            DisconnectHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer.deleteAccount = { _ in }
        }
        store.exhaustivity = .off
        await store.send(.disconnectConfirmed)
        await store.receive(\.disconnectFinished)
        #expect(!store.state.isProcessing)
    }

    @MainActor @Test func contactSupportBranchesOnCanSendMail() async {
        let mailStore = makeStore(canSendMail: true)
        mailStore.exhaustivity = .off
        await mailStore.send(.contactSupport)
        #expect(mailStore.state.supportData != nil)

        let shareStore = makeStore(canSendMail: false)
        shareStore.exhaustivity = .off
        await shareStore.send(.contactSupport)
        #expect(shareStore.state.messageToBeShared != nil)
    }

    @MainActor
    private func makeStore(canSendMail: Bool) -> TestStoreOf<DisconnectHWWallet> {
        var state = DisconnectHWWallet.State()
        state.canSendMail = canSendMail
        state.errMsg = "boom"
        return TestStore(initialState: state) {
            DisconnectHWWallet()
        } withDependencies: {
            $0.walletStorage = .noOp
        }
    }

    private func keystoneAccount() -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: "Keystone",
            keySource: String(localizable: .accountsKeystone).lowercased(),
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        ))
    }
}
