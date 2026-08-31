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
        // A real testnet unified address (same fixture as RequestZecTests /
        // DerivationToolTests), so the recipient is shielded and a memo is allowed.
        static let validUnifiedAddress = """
        utest1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzjanqtl8uqp5vln3zyy246ejtx86vqftp73j7jg9099jxafyjhfm6u956j3
        """
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
            $0.sdkSynchronizer.sendMaxAmount = { _, _, _ in resolvedAmount }
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
            $0.sdkSynchronizer.sendMaxAmount = { _, _, _ in throw MaxButtonTestError.sendMaxAmountFailed }
        }
        store.exhaustivity = .off

        await store.send(.maxTapped) {
            $0.isMaxRequestInFlight = true
        }
        await store.receive(\.maxAmountFailed)
        await store.finish()

        #expect(!store.state.isMaxRequestInFlight)
        #expect(store.state.zecAmountText == "1.5".redacted)
        #expect(store.state.toast == Toast.Edge.top(String(localizable: .generalMaxFailed)))
        state.$toast.withLock { $0 = nil }
    }

    // `.onDisapear` cancels the in-flight request; the flag must not stay stuck true
    // (the chip would spin forever), and the hint must not stay stuck visible now that
    // its dismiss timer gets genuinely cancelled.
    @MainActor @Test func onDisapearCancelsInFlightMaxRequestAndClearsFlags() async {
        var state = SendForm.State.initial
        state.isValidAddress = true
        state.isAddressBookHintVisible = true
        state.address = Const.validAddress.redacted
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        let store = TestStore(initialState: state) {
            SendForm()
        } withDependencies: {
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .testnet) }
            $0.sdkSynchronizer.sendMaxAmount = { _, _, _ in
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return Zatoshi(1)
            }
        }
        store.exhaustivity = .off

        await store.send(.maxTapped) {
            $0.isMaxRequestInFlight = true
        }
        await store.send(.onDisapear) {
            $0.isMaxRequestInFlight = false
            $0.isAddressBookHintVisible = false
        }
        await store.finish()
    }

    // The address field stays editable while the request runs; a result that comes back
    // for a different address than the one now in the field must be dropped.
    @MainActor @Test func maxAmountResolvedForStaleAddressIsDropped() async {
        var state = SendForm.State.initial
        state.isValidAddress = true
        state.address = Const.validUnifiedAddress.redacted
        state.zecAmountText = "1.5".redacted
        state.isMaxRequestInFlight = true

        let store = TestStore(initialState: state) {
            SendForm()
        }
        store.exhaustivity = .off

        await store.send(.maxAmountResolved(Const.validAddress.redacted, Zatoshi(123_456_789))) {
            $0.isMaxRequestInFlight = false
        }
        await store.finish()

        #expect(store.state.zecAmountText == "1.5".redacted)
        #expect(!store.state.isMaxRequestInFlight)
    }

    // The max must be computed for the exact proposal Review will build — including the
    // memo, which can change receiver selection and therefore the ZIP-317 fee.
    @MainActor @Test func maxTappedPassesUserMemoForShieldedRecipient() async {
        var state = SendForm.State.initial
        state.isValidAddress = true
        state.isValidTransparentAddress = false
        state.isValidTexAddress = false
        state.addMemoState = true
        state.memoState.text = "max memo test"
        state.address = Const.validUnifiedAddress.redacted
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        let memoUsed = LockIsolated<String?>("UNSET")

        let store = TestStore(initialState: state) {
            SendForm()
        } withDependencies: {
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .testnet) }
            $0.sdkSynchronizer.sendMaxAmount = { _, _, memo in
                memoUsed.setValue(memo?.toString())
                return Zatoshi(100_000)
            }
        }
        store.exhaustivity = .off

        await store.send(.maxTapped) {
            $0.isMaxRequestInFlight = true
        }
        await store.receive(\.maxAmountResolved)
        await store.finish()

        #expect(memoUsed.value == "max memo test")
    }

    // Transparent recipients cannot carry a memo — the max call must pass nil even
    // when the (soon to be cleared) memo field still holds text.
    @MainActor @Test func maxTappedPassesNilMemoForTransparentRecipient() async {
        var state = SendForm.State.initial
        state.isValidAddress = true
        state.isValidTransparentAddress = true
        state.addMemoState = true
        state.memoState.text = "should not ride along"
        state.address = Const.validAddress.redacted
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        let memoUsed = LockIsolated<String?>("UNSET")

        let store = TestStore(initialState: state) {
            SendForm()
        } withDependencies: {
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .testnet) }
            $0.sdkSynchronizer.sendMaxAmount = { _, _, memo in
                memoUsed.setValue(memo?.toString())
                return Zatoshi(100_000)
            }
        }
        store.exhaustivity = .off

        await store.send(.maxTapped) {
            $0.isMaxRequestInFlight = true
        }
        await store.receive(\.maxAmountResolved)
        await store.finish()

        #expect(memoUsed.value == nil)
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

    // The chip's progress state must key on the SDK's mask signal, never on "spendable is zero".
    // A spinner promises the figure is coming, so its condition has to be bounded — and the mask
    // is, by the tip refresh. These are the shapes that share a zero spendable balance but are NOT
    // the mask; each one would spin forever if the chip inferred from the balance instead.
    @Test func isSpendabilityBeingDeterminedTracksTheMaskAndNotAZeroBalance() {
        var state = SendForm.State.initial
        state.walletBalancesState.autoShieldingThreshold = Zatoshi(100_000)
        state.walletBalancesState.transparentBalance = .zero
        state.walletBalancesState.shieldedBalance = .zero
        state.walletBalancesState.totalBalance = Zatoshi(1_000_000)

        // Not masked: the SDK is not withholding anything, so no promise of a figure to come —
        // even though spendable is zero and `isProcessingZeroAvailableBalance` is true here.
        #expect(state.walletBalancesState.isProcessingZeroAvailableBalance)
        #expect(!state.isSpendabilityBeingDetermined)

        // Masked: the SDK says it is not ready to report spendable yet.
        state.walletBalancesState.isSpendableMasked = true
        #expect(state.isSpendabilityBeingDetermined)

        // Tip refreshed — the mask lifts and the chip must stop spinning, whatever the balance is.
        state.walletBalancesState.isSpendableMasked = false
        #expect(!state.isSpendabilityBeingDetermined)

        // Sub-threshold transparent-only wallet: 50_000 zats against a 100_000 threshold is not
        // shieldable, so `isProcessingZeroAvailableBalance` is permanently true. Keying the chip on
        // it would spin forever, promising a figure that never arrives (review item 1).
        state.walletBalancesState.transparentBalance = Zatoshi(50_000)
        state.walletBalancesState.totalBalance = Zatoshi(50_000)
        #expect(state.walletBalancesState.isProcessingZeroAvailableBalance)
        #expect(!state.isSpendabilityBeingDetermined)
    }

    // While masked the chip is BOTH disabled and in-flight: `isMaxButtonEnabled` is false because
    // spendable is zero, and `isSpendabilityBeingDetermined` is true. ZashiMaxChip renders the
    // spinner and refuses taps on either, so the chip stays untappable — it just stops claiming to
    // be unavailable. Asserting the pair together is the regression guard: re-enabling the chip
    // while the value is unknown would let a tap compute a max against a masked (zero) balance.
    @Test func maskedStateLeavesTheChipUntappableButShowingProgress() {
        var state = SendForm.State.initial
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        state.isValidAddress = true
        state.walletBalancesState.isSpendableMasked = true
        state.walletBalancesState.shieldedBalance = .zero
        state.walletBalancesState.totalBalance = Zatoshi(1_000_000)
        state.walletBalancesState.spendability = .nothing
        state.shieldedBalance = .zero

        #expect(state.isSpendabilityBeingDetermined)
        #expect(!state.isMaxButtonEnabled)
    }

    // Review item 2: under the mask `shieldedBalance` is a zero the SDK is not standing behind, so
    // `isInsufficientFunds` withholds its verdict instead of accusing the user of lacking funds
    // that are genuinely spendable. Withholding it would on its own let `isValidForm` read as
    // approval and enable Review on that same masked zero — so the form gates on the signal too.
    // This pins that pairing; dropping either half re-breaks one of the two directions.
    //
    // Only the Review half is reachable here: `SendForm.State.amount` is stubbed to `.zero` under
    // `_XCTIsTesting` (see the file header), so `isInsufficientFunds` returns false in this target
    // whatever the balance is, and its guard cannot be exercised by a unit test.
    @Test func maskedBalanceKeepsReviewDisabledRatherThanReadingAsApproval() {
        var state = SendForm.State.initial
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        state.isValidAddress = true
        state.address = Const.validAddress.redacted
        state.shieldedBalance = .zero
        state.walletBalancesState.shieldedBalance = .zero
        state.walletBalancesState.totalBalance = Zatoshi(1_000_000)

        // Masked: no accusation, and no approval either.
        state.walletBalancesState.isSpendableMasked = true
        #expect(!state.isInsufficientFunds)
        #expect(!state.isValidForm)

        // Mask lifted: the form is judged on the real figure again.
        state.walletBalancesState.isSpendableMasked = false
        #expect(state.isValidForm)
    }
}
