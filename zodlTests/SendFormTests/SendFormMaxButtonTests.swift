//
//  SendFormMaxButtonTests.swift
//  zodlTests
//
//  Covers SendForm's Max-button reducer logic (Features/SendForm/SendFormStore.swift):
//  .maxTapped / .maxAmountResolved / .maxAmountFailed, and the isMaxButtonEnabled gate.
//  NOTE: state.amount/isValidAmount/isInvalidAmountFormat are _XCTIsTesting-poisoned;
//  assertions here go through zecAmountText instead, matching SendFormAddressValidationTests.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

private enum MaxButtonTestError: Error {
    case sendMaxAmountFailed
}

@Suite(.serialized) struct SendFormMaxButtonTests {
    private enum Const {
        // A real testnet transparent address (also used by FlexaSecurityTests /
        // MultiServerSubmitFlexaRoutingTests) so the reducer's real Recipient(_:network:)
        // parse succeeds under test rather than throwing recipientInvalidInput.
        static let validAddress = "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE"
    }

    private var testWalletAccount: WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0, count: 16)),
                name: "Test",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    // Isolates the FIRST guard in `.maxTapped`. A valid `selectedWalletAccount` is set so the
    // second guard (`guard let account = state.selectedWalletAccount`) cannot fire and mask it —
    // without this the test would still pass with the address guard deleted. `selectedWalletAccount`
    // is process-global `@Shared(.inMemory(...))` state that sibling tests set, so it is pinned here
    // rather than relied upon to be nil.
    @MainActor @Test func maxTappedWithInvalidAddressDoesNothing() async {
        var state = SendForm.State.initial
        state.isValidAddress = false
        state.address = Const.validAddress.redacted
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        // `sendMaxAmount` is left unimplemented on purpose: if the address guard stopped
        // working, the effect would run and the unimplemented dependency would fail the test.
        let store = TestStore(initialState: state) {
            SendForm()
        }

        await store.send(.maxTapped)
        await store.finish()

        #expect(!store.state.isMaxRequestInFlight)
    }

    @MainActor @Test func maxTappedWithValidAddressResolvesMaxAmountIntoZecAmountText() async {
        var state = SendForm.State.initial
        state.isValidAddress = true
        state.address = Const.validAddress.redacted
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        let resolvedAmount = Zatoshi(123_456_789)

        let store = TestStore(initialState: state) {
            SendForm()
        } withDependencies: {
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .testnet) }
            $0.sdkSynchronizer.sendMaxAmount = { _, _ in resolvedAmount }
        }
        store.exhaustivity = .off

        await store.send(.maxTapped) {
            $0.isMaxRequestInFlight = true
        }
        await store.receive(\.maxAmountResolved)
        await store.receive(\.zecAmountUpdated)
        await store.finish()

        #expect(store.state.zecAmountText == resolvedAmount.decimalString().redacted)
        #expect(!store.state.isMaxRequestInFlight)
    }

    @MainActor @Test func maxTappedFailurePathClearsInFlightFlagAndLeavesAmountUnchanged() async {
        var state = SendForm.State.initial
        state.isValidAddress = true
        state.address = Const.validAddress.redacted
        state.zecAmountText = "1.5".redacted
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        let store = TestStore(initialState: state) {
            SendForm()
        } withDependencies: {
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .testnet) }
            $0.sdkSynchronizer.sendMaxAmount = { _, _ in throw MaxButtonTestError.sendMaxAmountFailed }
        }
        store.exhaustivity = .off

        await store.send(.maxTapped) {
            $0.isMaxRequestInFlight = true
        }
        await store.receive(\.maxAmountFailed)
        await store.finish()

        #expect(!store.state.isMaxRequestInFlight)
        #expect(store.state.zecAmountText == "1.5".redacted)
    }

    @Test func isMaxButtonEnabledReflectsAddressBalanceAndInFlightState() {
        var state = SendForm.State.initial
        // `selectedWalletAccount` is process-global `@Shared` state; Swift Testing runs
        // OTHER suites in parallel, so pin it and always restore the previous value.
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        state.isValidAddress = true
        state.shieldedBalance = Zatoshi(100_000)
        state.walletBalancesState.spendability = .everything
        #expect(state.isMaxButtonEnabled)

        state.isValidAddress = false
        #expect(!state.isMaxButtonEnabled)
        state.isValidAddress = true

        state.walletBalancesState.spendability = .nothing
        #expect(!state.isMaxButtonEnabled)

        state.walletBalancesState.spendability = .something
        #expect(state.isMaxButtonEnabled)

        // Empty wallet: spendability is `.everything` when totalBalance == .zero (and as
        // the initial value), so a zero spendable balance must gate the chip off on its own.
        state.walletBalancesState.spendability = .everything
        state.shieldedBalance = .zero
        #expect(!state.isMaxButtonEnabled)
        state.shieldedBalance = Zatoshi(100_000)

        state.$selectedWalletAccount.withLock { $0 = nil }
        #expect(!state.isMaxButtonEnabled)
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }

        state.isMaxRequestInFlight = true
        #expect(!state.isMaxButtonEnabled)
    }
}
