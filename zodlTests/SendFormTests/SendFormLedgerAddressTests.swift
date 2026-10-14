//
//  SendFormLedgerAddressTests.swift
//  zodlTests
//
//  MOB-2020 Phase 3.3: covers the Ledger-specific address-type gate in SendForm
//  (Features/SendForm/SendFormStore.swift) -- a Ledger device refuses to sign a Sapling output, so
//  `isLedgerUnsupportedAddress` blocks the form for a Sapling recipient on a Ledger account only,
//  and the TEX explainer sheet (`isSheetTexAddressVisible`) now shows for every hardware wallet
//  instead of Keystone alone. Isolated via `withDependencies { $0.defaultInMemoryStorage =
//  InMemoryStorage() }` since `SendForm.State.selectedWalletAccount` is process-global `@Shared`
//  storage -- same idiom as `ShieldingProcessorLiveKeyTests.swift`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZODLSwiftWalletSDK

@Suite(.serialized) struct SendFormLedgerAddressTests {
    private static func ledgerAccount() -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0x0E, count: 16)),
                name: "Ledger",
                keySource: "ledger",
                seedFingerprint: nil,
                hdAccountIndex: nil,
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private static func keystoneAccount() -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0x0F, count: 16)),
                name: "Keystone",
                keySource: "keystone",
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    @MainActor @Test func aSaplingAddressIsRefusedForALedgerAccount() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(address: "saplingaddr", account: Self.ledgerAccount(), isZcash: true, isSapling: true)
            await store.send(.validateAddress)

            #expect(store.state.isValidAddress)
            #expect(store.state.isLedgerUnsupportedAddress)
            #expect(!store.state.isValidForm)
            #expect(store.state.invalidAddressErrorText == String(localizable: .ledgerSendUnsupportedAddress))
        }
    }

    @MainActor @Test func aSaplingAddressIsAcceptedForAKeystoneAccount() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(address: "saplingaddr", account: Self.keystoneAccount(), isZcash: true, isSapling: true)
            await store.send(.validateAddress)

            #expect(store.state.isValidAddress)
            #expect(!store.state.isLedgerUnsupportedAddress)
            #expect(store.state.isValidForm)
            #expect(store.state.invalidAddressErrorText == nil)
        }
    }

    @MainActor @Test func aUnifiedAddressIsAcceptedForALedgerAccount() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            // A unified address is neither Sapling nor TEX -- only `isZcashAddress` answers true.
            let store = makeStore(address: "unifiedaddr", account: Self.ledgerAccount(), isZcash: true, isSapling: false)
            await store.send(.validateAddress)

            #expect(store.state.isValidAddress)
            #expect(!store.state.isLedgerUnsupportedAddress)
            #expect(store.state.isValidForm)
            #expect(store.state.invalidAddressErrorText == nil)
        }
    }

    @MainActor @Test func aTexAddressShowsTheExplainerSheetForALedgerAccount() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(address: "texaddr", account: Self.ledgerAccount(), isTex: true)
            await store.send(.validateAddress)

            #expect(store.state.isValidTexAddress)
            #expect(store.state.isSheetTexAddressVisible)
        }
    }

    @MainActor
    private func makeStore(
        address: String,
        account: WalletAccount,
        isZcash: Bool = false,
        isTransparent: Bool = false,
        isTex: Bool = false,
        isSapling: Bool = false
    ) -> TestStoreOf<SendForm> {
        var state = SendForm.State.initial
        state.address = address.redacted
        state.$selectedWalletAccount.withLock { $0 = account }
        let store = TestStore(initialState: state) {
            SendForm()
        } withDependencies: {
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .testnet) }
            $0.derivationTool.isZcashAddress = { _, _ in isZcash }
            $0.derivationTool.isTransparentAddress = { _, _ in isTransparent }
            $0.derivationTool.isTexAddress = { _, _ in isTex }
            $0.derivationTool.isSaplingAddress = { _, _ in isSapling }
        }
        store.exhaustivity = .off
        return store
    }
}
