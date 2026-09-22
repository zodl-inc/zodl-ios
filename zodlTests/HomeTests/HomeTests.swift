//
//  HomeTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 02.06.2022.
//

@preconcurrency import Combine
import Testing
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

// `Home.State` carries `@Shared(.inMemory(.selectedWalletAccount))` process-global storage.
// `.serialized` orders this suite's own tests so the account-vendor tests below cannot race each
// other; none of the other tests in this file touch that key.
@Suite(.serialized) struct HomeTests {
    private static func account(idByte: UInt8, vendor: WalletAccount.Vendor) -> WalletAccount {
        let keySource: String?
        switch vendor {
        case .keystone: keySource = "keystone"
        case .ledger: keySource = "ledger"
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

    // MARK: - isHWWalletAccountActive

    @Test func isHWWalletAccountActiveIsTrueForKeystoneAndLedgerAndFalseForZodl() {
        var state = Home.State.initial

        state.$selectedWalletAccount.withLock { $0 = Self.account(idByte: 0x01, vendor: .keystone) }
        #expect(state.isHWWalletAccountActive)

        state.$selectedWalletAccount.withLock { $0 = Self.account(idByte: 0x02, vendor: .ledger) }
        #expect(state.isHWWalletAccountActive)

        state.$selectedWalletAccount.withLock { $0 = Self.account(idByte: 0x03, vendor: .zcash) }
        #expect(!state.isHWWalletAccountActive)
    }

    @MainActor @Test func synchronizerErrorBringsUpAlert() async {
        let testError = ZcashError.synchronizerNotPrepared

        var state = SynchronizerState.zero
        state.syncStatus = .error(testError)

        let store = TestStore(
            initialState: .initial
        ) {
            Home()
        }

        await store.send(.synchronizerStateChanged(state.redacted))

        await store.receive(.showSynchronizerErrorAlert(testError))

        await store.finish()
    }

    @MainActor @Test func balanceTappedPresentsPoolBalancesSheet() async {
        let store = TestStore(
            initialState: .initial
        ) {
            Home()
        }

        await store.send(.walletBalances(.balanceTapped)) {
            $0.poolBalancesRequest = true
        }

        await store.finish()
    }

    @MainActor @Test func poolBalancesDismissTappedHidesPoolBalancesSheet() async {
        var initialState = Home.State.initial
        initialState.poolBalancesRequest = true

        let store = TestStore(
            initialState: initialState
        ) {
            Home()
        }

        await store.send(.poolBalancesDismissTapped) {
            $0.poolBalancesRequest = false
        }

        await store.finish()
    }
}
