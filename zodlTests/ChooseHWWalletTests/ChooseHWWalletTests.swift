//
//  ChooseHWWalletTests.swift
//  zodlTests
//
//  Covers ChooseHWWallet's derived connection flags for the four Keystone/Ledger combinations,
//  and that its three actions leave state untouched
//  (Features/ChooseHWWallet/ChooseHWWalletStore.swift).
//

import Testing
import ComposableArchitecture
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

// `ChooseHWWallet.State` carries `@Shared(.inMemory(.walletAccounts))` process-global storage,
// same reason HomeTests/AddLedgerHWWalletTests are `.serialized`.
@Suite(.serialized) struct ChooseHWWalletTests {
    private static func account(idByte: UInt8, vendor: WalletAccount.Vendor) -> WalletAccount {
        let keySource: String?
        switch vendor {
        case .keystone: keySource = Account.keystoneKeySource
        case .ledger: keySource = Account.ledgerKeySource
        case .zcash: keySource = nil
        }
        return WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: "Test",
                keySource: keySource,
                seedFingerprint: nil,
                hdAccountIndex: vendor == .ledger ? nil : Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    // MARK: - isKeystoneConnected / isLedgerConnected

    @Test func connectionFlagsReflectTheSharedAccountsForAllFourCombinations() {
        var state = ChooseHWWallet.State()

        state.$walletAccounts.withLock { $0 = [] }
        #expect(!state.isKeystoneConnected)
        #expect(!state.isLedgerConnected)

        state.$walletAccounts.withLock { $0 = [Self.account(idByte: 0x01, vendor: .keystone)] }
        #expect(state.isKeystoneConnected)
        #expect(!state.isLedgerConnected)

        state.$walletAccounts.withLock { $0 = [Self.account(idByte: 0x02, vendor: .ledger)] }
        #expect(!state.isKeystoneConnected)
        #expect(state.isLedgerConnected)

        state.$walletAccounts.withLock {
            $0 = [
                Self.account(idByte: 0x03, vendor: .keystone),
                Self.account(idByte: 0x04, vendor: .ledger)
            ]
        }
        #expect(state.isKeystoneConnected)
        #expect(state.isLedgerConnected)
    }

    // MARK: - Actions leave state untouched

    @MainActor @Test func actionsLeaveStateUntouched() async {
        let store = TestStore(initialState: ChooseHWWallet.State()) { ChooseHWWallet() }

        await store.send(.keystoneTapped)
        await store.send(.ledgerTapped)
        await store.send(.closeTapped)
    }
}
