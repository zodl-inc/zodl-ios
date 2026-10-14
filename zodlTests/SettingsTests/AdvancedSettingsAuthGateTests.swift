//
//  AdvancedSettingsAuthGateTests.swift
//  zodlTests
//
//  Batch 6 — settings/security. Completes the AdvancedSettings auth-gate matrix
//  (Features/Settings/AdvancedSettingsStore.swift). Complements AdvancedSettingsTests.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZODLSwiftWalletSDK

@Suite(.serialized) struct AdvancedSettingsAuthGateTests {
    private static let sensitiveOperations: [AdvancedSettings.State.Operation] = [
        .recoveryPhrase, .exportPrivateData, .exportTaxFile, .resetZashi, .disconnectHWWallet, .resyncWallet
    ]

    @MainActor @Test(arguments: sensitiveOperations)
    func sensitiveOperationGrantedOnAuthSuccess(_ operation: AdvancedSettings.State.Operation) async {
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationSucceeded
        }
        await store.send(.operationAccessCheck(operation))
        await store.receive(.operationAccessGranted(operation))
        await store.finish()
    }

    @MainActor @Test(arguments: sensitiveOperations)
    func sensitiveOperationDeniedOnAuthFailure(_ operation: AdvancedSettings.State.Operation) async {
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationFailed
        }
        // A failed authentication must NOT emit operationAccessGranted.
        await store.send(.operationAccessCheck(operation))
        await store.finish()
    }

    @MainActor @Test func torSetupBypassesAuthentication() async {
        // localAuthentication is intentionally left unimplemented: torSetup must not invoke it.
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        }
        await store.send(.operationAccessCheck(.torSetup))
        await store.receive(.operationAccessGranted(.torSetup))
        await store.finish()
    }

    /// MOB-2020: Advanced Settings follows the SELECTED account, not "is any hardware wallet
    /// connected" -- the row (and the gate it feeds) stays hidden for a Zodl account even while a
    /// Keystone and a Ledger are both connected elsewhere in the wallet.
    @Test func theDisconnectRowFollowsTheSelectedAccount() {
        var state = AdvancedSettings.State()
        state.$walletAccounts.withLock { $0 = [keystoneAccount(), ledgerAccount()] }

        state.$selectedWalletAccount.withLock { $0 = nil }
        #expect(!state.isHWWalletAccountSelected)

        state.$selectedWalletAccount.withLock { $0 = zodlAccount() }
        #expect(!state.isHWWalletAccountSelected)

        state.$selectedWalletAccount.withLock { $0 = keystoneAccount() }
        #expect(state.isHWWalletAccountSelected)

        state.$selectedWalletAccount.withLock { $0 = ledgerAccount() }
        #expect(state.isHWWalletAccountSelected)
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
