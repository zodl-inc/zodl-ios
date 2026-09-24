//
//  DisconnectHWWalletTests.swift
//  zodlTests
//
//  More tests — hardware wallet. Covers DisconnectHWWallet state machine + support routing
//  (Features/DisconnectHWWallet/DisconnectHWWalletStore.swift).
//
//  MOB-2020 Phase 2 (review notes): this screen follows the SELECTED account, not "whichever
//  hardware wallet is connected" -- `vendor` derives from `selectedWalletAccount` instead of the
//  old standalone `selectedVendor` / `connectedHWVendors` pick-a-card model, so a Keystone
//  account's row disconnects only the Keystone and a Ledger account's row disconnects only the
//  Ledger, even when both are connected. A Ledger disconnect additionally drops its keychain
//  binding, its encryption keys, and closes the Bluetooth link.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct DisconnectHWWalletTests {
    // MARK: - vendor

    @Test func theVendorFollowsTheSelectedAccount() {
        var state = DisconnectHWWallet.State()

        state.$selectedWalletAccount.withLock { $0 = nil }
        #expect(state.vendor == nil)

        state.$selectedWalletAccount.withLock { $0 = zodlAccount() }
        #expect(state.vendor == nil)

        state.$selectedWalletAccount.withLock { $0 = keystoneAccount() }
        #expect(state.vendor == .keystone)

        state.$selectedWalletAccount.withLock { $0 = ledgerAccount() }
        #expect(state.vendor == .ledger)
    }

    // MARK: - disconnectTapped

    @MainActor @Test func disconnectTappedShowsSheetAndProcesses() async {
        var state = DisconnectHWWallet.State()
        state.$selectedWalletAccount.withLock { $0 = keystoneAccount() }
        let store = TestStore(initialState: state) { DisconnectHWWallet() }
        await store.send(.disconnectTapped) {
            $0.isSheetUp = true
            $0.isProcessing = true
        }
    }

    @MainActor @Test func disconnectTappedWithoutASelectionIsNoOp() async {
        var state = DisconnectHWWallet.State()
        state.$selectedWalletAccount.withLock { $0 = nil }
        let store = TestStore(initialState: state) { DisconnectHWWallet() }
        await store.send(.disconnectTapped)
    }

    @MainActor @Test func disconnectTappedWithAZodlAccountSelectedIsNoOp() async {
        var state = DisconnectHWWallet.State()
        state.$selectedWalletAccount.withLock { $0 = zodlAccount() }
        let store = TestStore(initialState: state) { DisconnectHWWallet() }
        await store.send(.disconnectTapped)
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

    // MARK: - disconnectConfirmed

    @MainActor @Test func disconnectConfirmedWithoutKeystoneIsNoOp() async {
        var state = DisconnectHWWallet.State()
        state.isSheetUp = true
        // Nothing selected -- still a no-op.
        state.$selectedWalletAccount.withLock { $0 = nil }
        let store = TestStore(initialState: state) { DisconnectHWWallet() }
        await store.send(.disconnectConfirmed) { $0.isSheetUp = false }
    }

    @MainActor @Test func disconnectConfirmedWithKeystoneDeletesAccount() async {
        var state = DisconnectHWWallet.State(isProcessing: true)
        state.isSheetUp = true
        state.$selectedWalletAccount.withLock { $0 = keystoneAccount() }
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

    @MainActor @Test func disconnectConfirmedWithKeystoneOnlyDeletesTheAccount() async {
        var state = DisconnectHWWallet.State(isProcessing: true)
        state.isSheetUp = true
        state.$selectedWalletAccount.withLock { $0 = keystoneAccount() }

        let deletedAccountId = LockIsolated<AccountUUID?>(nil)
        let bindingDeleteCount = LockIsolated(0)
        let keysClearCount = LockIsolated(0)
        let ledgerDisconnectCount = LockIsolated(0)

        let store = TestStore(initialState: state) {
            DisconnectHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer.deleteAccount = { id in deletedAccountId.setValue(id) }
            $0.walletStorage = .noOp
            $0.walletStorage.deleteLedgerBinding = { _ in bindingDeleteCount.withValue { $0 += 1 } }
            $0.walletStorage.clearEncryptionKeys = { _ in keysClearCount.withValue { $0 += 1 } }
            $0.ledgerClient = .noOp
            $0.ledgerClient.disconnect = { ledgerDisconnectCount.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.disconnectConfirmed)
        await store.receive(\.disconnectFinished)
        await store.finish()

        #expect(deletedAccountId.value == keystoneAccount().id)
        #expect(bindingDeleteCount.value == 0)
        #expect(keysClearCount.value == 0)
        #expect(ledgerDisconnectCount.value == 0)
    }

    @MainActor @Test func disconnectConfirmedWithLedgerDeletesTheAccountItsBindingAndItsKeysAndClosesTheLink() async {
        var state = DisconnectHWWallet.State(isProcessing: true)
        state.isSheetUp = true
        state.$selectedWalletAccount.withLock { $0 = ledgerAccount() }

        let deletedAccountId = LockIsolated<AccountUUID?>(nil)
        let deletedBindingId = LockIsolated<AccountUUID?>(nil)
        let clearedKeysAccount = LockIsolated<Account?>(nil)
        let ledgerDisconnectCount = LockIsolated(0)

        let store = TestStore(initialState: state) {
            DisconnectHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer.deleteAccount = { id in deletedAccountId.setValue(id) }
            $0.walletStorage = .noOp
            $0.walletStorage.deleteLedgerBinding = { id in deletedBindingId.setValue(id) }
            $0.walletStorage.clearEncryptionKeys = { account in clearedKeysAccount.setValue(account) }
            $0.ledgerClient = .noOp
            $0.ledgerClient.disconnect = { ledgerDisconnectCount.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.disconnectConfirmed)
        await store.receive(\.disconnectFinished)
        await store.finish()

        let expected = ledgerAccount()
        #expect(deletedAccountId.value == expected.id)
        #expect(deletedBindingId.value == expected.id)
        #expect(clearedKeysAccount.value == expected.account)
        #expect(ledgerDisconnectCount.value == 1)
    }

    @MainActor @Test func disconnectFailedForLedgerLeavesTheBindingInPlace() async {
        struct DeleteAccountFailure: Error { }

        var state = DisconnectHWWallet.State(isProcessing: true)
        state.isSheetUp = true
        state.$selectedWalletAccount.withLock { $0 = ledgerAccount() }

        let bindingDeleteCount = LockIsolated(0)
        let keysClearCount = LockIsolated(0)
        let ledgerDisconnectCount = LockIsolated(0)

        let store = TestStore(initialState: state) {
            DisconnectHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer.deleteAccount = { _ in throw DeleteAccountFailure() }
            $0.walletStorage = .noOp
            $0.walletStorage.deleteLedgerBinding = { _ in bindingDeleteCount.withValue { $0 += 1 } }
            $0.walletStorage.clearEncryptionKeys = { _ in keysClearCount.withValue { $0 += 1 } }
            $0.ledgerClient = .noOp
            $0.ledgerClient.disconnect = { ledgerDisconnectCount.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.disconnectConfirmed)
        await store.receive(\.disconnectFailed)
        await store.finish()

        #expect(bindingDeleteCount.value == 0)
        #expect(keysClearCount.value == 0)
        #expect(ledgerDisconnectCount.value == 0)
        #expect(store.state.isFailureSheetUp)
        #expect(!store.state.isProcessing)
    }

    /// MOB-2020: with a Keystone AND a Ledger both connected, selecting the Ledger account must
    /// touch only the Ledger -- the connected Keystone is never looked at.
    @MainActor @Test func disconnectConfirmedWithTheLedgerSelectedLeavesTheConnectedKeystoneAlone() async {
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        $walletAccounts.withLock { $0 = [zodlAccount(), keystoneAccount(), ledgerAccount()] }

        var state = DisconnectHWWallet.State(isProcessing: true)
        state.isSheetUp = true
        state.$selectedWalletAccount.withLock { $0 = ledgerAccount() }

        let deletedAccountId = LockIsolated<AccountUUID?>(nil)
        let deletedBindingId = LockIsolated<AccountUUID?>(nil)
        let clearedKeysAccount = LockIsolated<Account?>(nil)
        let ledgerDisconnectCount = LockIsolated(0)

        let store = TestStore(initialState: state) {
            DisconnectHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer.deleteAccount = { id in deletedAccountId.setValue(id) }
            $0.walletStorage = .noOp
            $0.walletStorage.deleteLedgerBinding = { id in deletedBindingId.setValue(id) }
            $0.walletStorage.clearEncryptionKeys = { account in clearedKeysAccount.setValue(account) }
            $0.ledgerClient = .noOp
            $0.ledgerClient.disconnect = { ledgerDisconnectCount.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.disconnectConfirmed)
        await store.receive(\.disconnectFinished)
        await store.finish()

        let expected = ledgerAccount()
        #expect(deletedAccountId.value == expected.id)
        #expect(deletedBindingId.value == expected.id)
        #expect(clearedKeysAccount.value == expected.account)
        #expect(ledgerDisconnectCount.value == 1)
    }

    /// MOB-2020: with a Keystone AND a Ledger both connected, selecting the Keystone account must
    /// touch only the Keystone -- the connected Ledger's binding, keys and Bluetooth link are
    /// never touched.
    @MainActor @Test func disconnectConfirmedWithTheKeystoneSelectedLeavesTheConnectedLedgerAlone() async {
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        $walletAccounts.withLock { $0 = [zodlAccount(), keystoneAccount(), ledgerAccount()] }

        var state = DisconnectHWWallet.State(isProcessing: true)
        state.isSheetUp = true
        state.$selectedWalletAccount.withLock { $0 = keystoneAccount() }

        let deletedAccountId = LockIsolated<AccountUUID?>(nil)
        let bindingDeleteCount = LockIsolated(0)
        let keysClearCount = LockIsolated(0)
        let ledgerDisconnectCount = LockIsolated(0)

        let store = TestStore(initialState: state) {
            DisconnectHWWallet()
        } withDependencies: {
            $0.sdkSynchronizer.deleteAccount = { id in deletedAccountId.setValue(id) }
            $0.walletStorage = .noOp
            $0.walletStorage.deleteLedgerBinding = { _ in bindingDeleteCount.withValue { $0 += 1 } }
            $0.walletStorage.clearEncryptionKeys = { _ in keysClearCount.withValue { $0 += 1 } }
            $0.ledgerClient = .noOp
            $0.ledgerClient.disconnect = { ledgerDisconnectCount.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.disconnectConfirmed)
        await store.receive(\.disconnectFinished)
        await store.finish()

        #expect(deletedAccountId.value == keystoneAccount().id)
        #expect(bindingDeleteCount.value == 0)
        #expect(keysClearCount.value == 0)
        #expect(ledgerDisconnectCount.value == 0)
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

    private func zodlAccount() -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: 0x00, count: 16)),
            name: "Zodl",
            keySource: nil,
            seedFingerprint: [UInt8](repeating: 0x00, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        ))
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

    private func ledgerAccount() -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: 0x03, count: 16)),
            name: "Ledger",
            keySource: "ledger",
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
            uivk: nil
        ))
    }
}
