//
//  SwapAndPayMaxButtonTests.swift
//  zodlTests
//
//  Covers SwapAndPay's Max-chip reducer logic (Features/SwapAndPayForm/SwapAndPayStore.swift):
//  .maxTapped / .maxAmountResolved / .maxAmountFailed across the three modes the one reducer
//  serves (Swap ZEC->token, Swap token->ZEC, Pay), plus the two chip-enablement gates.
//  NOTE: state.amount/assetAmount/usdAmount are _XCTIsTesting-poisoned to 0, so every assertion
//  goes through the raw *Text fields, parsed back with the reducer's own formatters.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

private enum SwapMaxButtonTestError: Error {
    case sendMaxAmountFailed
}

@Suite(.serialized) struct SwapAndPayMaxButtonTests {
    private enum Const {
        /// A real testnet transparent address, so `TransparentAddress(encoding:network:)` really
        /// validates rather than being faked.
        static let transparentAddress = "tmP3uLtGx5GPddkq8a6ddmXhqJJ3vy6tpTE"
        /// 1.23456789 ZEC, chosen so anything that rounds to 2 decimals is visible in the result.
        static let maxAmount = Zatoshi(123_456_789)
        /// 1.996 ZEC — `simplified` takes this UP to 2.00, above the max (0.2% away, inside its
        /// 0.5% tolerance). Anything that reintroduces rounding-to-nearest here overshoots.
        static let roundsUpMaxAmount = Zatoshi(199_600_000)
        /// 1.23465 ZEC — at $40 that is exactly $49.386, which the floor-to-cents fill takes DOWN
        /// to $49.38 while `simplified` would take it UP to $49.39, i.e. above the max.
        static let usdRoundsUpMaxAmount = Zatoshi(123_465_000)
        /// 1234.5678 ZEC — over the grouping threshold, so `formatter` would emit "1,234.5678"
        /// while `conversionFormatter` (grouping off) emits the parseable "1234.5678".
        static let groupedMaxAmount = Zatoshi(123_456_780_000)
        static let zecUsdPrice = Decimal(40)
        static let tokenUsdPrice = Decimal(2)
    }

    private var maxZec: Decimal {
        Const.maxAmount.decimalValue.decimalValue
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

    private func asset(token: String, usdPrice: Decimal) -> SwapAsset {
        SwapAsset(provider: "near", chain: token.lowercased(), token: token, assetId: "\(token)-id", usdPrice: usdPrice, decimals: 8)
    }

    /// Swap ZEC -> token, ZEC input. This is the mode the chip is rendered in by default.
    private func swapState() -> SwapAndPay.State {
        var state = SwapAndPay.State.initial
        state.isSwapExperienceEnabled = true
        state.isSwapToZecExperienceEnabled = false
        state.isInputInUsd = false
        state.zecAsset = asset(token: "ZEC", usdPrice: Const.zecUsdPrice)
        state.selectedAsset = asset(token: "BTC", usdPrice: Const.tokenUsdPrice)
        state.walletBalancesState.spendability = .everything
        state.walletBalancesState.shieldedBalance = Zatoshi(500_000_000)
        return state
    }

    /// Pay / CrossPay: both experience flags off.
    private func payState() -> SwapAndPay.State {
        var state = swapState()
        state.isSwapExperienceEnabled = false
        return state
    }

    // MARK: - .maxTapped

    // The chip proposes against this account's OWN transparent receiver, because the real
    // recipient (the provider's deposit address) does not exist until a quote has been made.
    @MainActor @Test func maxTappedProposesAgainstOwnTransparentReceiverAndFillsTheField() async {
        let recipientUsed = LockIsolated<String?>(nil)

        var state = swapState()
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        let store = TestStore(initialState: state) {
            SwapAndPay()
        } withDependencies: {
            // `getTransparentAddress` is a `let` on the client, so the whole client is replaced
            // rather than a single closure being overridden in place.
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getTransparentAddress: { _ in try? TransparentAddress(encoding: Const.transparentAddress, network: .testnet) },
                sendMaxAmount: { _, recipient in
                    recipientUsed.setValue(recipient.stringEncoded)
                    return Const.maxAmount
                }
            )
        }
        store.exhaustivity = .off

        await store.send(.maxTapped) {
            $0.isMaxRequestInFlight = true
        }
        await store.receive(\.maxAmountResolved)
        await store.finish()

        #expect(recipientUsed.value == Const.transparentAddress)
        #expect(!store.state.isMaxRequestInFlight)
        #expect(store.state.amountText == store.state.conversionFormatter.string(from: NSDecimalNumber(decimal: maxZec)))
    }

    // Swapping INTO ZEC spends no ZEC from this wallet — no chip is rendered and the action
    // must not reach the SDK (both stubs are left unimplemented so a leak fails the test).
    @MainActor @Test func maxTappedInSwapToZecModeIsNoOp() async {
        var state = swapState()
        state.isSwapToZecExperienceEnabled = true

        let store = TestStore(initialState: state) {
            SwapAndPay()
        }

        await store.send(.maxTapped)
        await store.finish()

        #expect(!store.state.isMaxRequestInFlight)
        #expect(store.state.amountText.isEmpty)
    }

    @MainActor @Test func maxTappedWithoutSelectedAccountIsNoOp() async {
        var state = swapState()
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = nil }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        let store = TestStore(initialState: state) {
            SwapAndPay()
        }

        await store.send(.maxTapped)
        await store.finish()

        #expect(!store.state.isMaxRequestInFlight)
        #expect(store.state.amountText.isEmpty)
    }

    // A wallet with no transparent receiver cannot be proposed against; that must fail cleanly
    // rather than filling the field with something wrong.
    @MainActor @Test func maxTappedWithoutTransparentAddressFails() async {
        var state = swapState()
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        let store = TestStore(initialState: state) {
            SwapAndPay()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(getTransparentAddress: { _ in nil })
        }
        store.exhaustivity = .off

        await store.send(.maxTapped) {
            $0.isMaxRequestInFlight = true
        }
        await store.receive(\.maxAmountFailed)
        await store.finish()

        #expect(!store.state.isMaxRequestInFlight)
        #expect(store.state.amountText.isEmpty)
    }

    @MainActor @Test func maxTappedFailurePathClearsInFlightFlagAndLeavesFieldsUntouched() async {
        var state = swapState()
        state.amountText = "1.5"
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        let store = TestStore(initialState: state) {
            SwapAndPay()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getTransparentAddress: { _ in try? TransparentAddress(encoding: Const.transparentAddress, network: .testnet) },
                sendMaxAmount: { _, _ in throw SwapMaxButtonTestError.sendMaxAmountFailed }
            )
        }
        store.exhaustivity = .off

        await store.send(.maxTapped) {
            $0.isMaxRequestInFlight = true
        }
        await store.receive(\.maxAmountFailed)
        await store.finish()

        #expect(!store.state.isMaxRequestInFlight)
        #expect(store.state.amountText == "1.5")
    }

    // MARK: - .maxAmountResolved, Swap ZEC -> token

    // The plain ZEC string must keep full zatoshi precision: `simplified` (used by the sibling
    // switch-input path) rounds to nearest and could put the field ABOVE the spendable balance.
    @MainActor @Test func maxAmountResolvedFillsPlainZecAmountInSwapMode() async {
        let store = TestStore(initialState: swapState()) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.maxAmountResolved(Const.maxAmount))

        let formatter = store.state.conversionFormatter
        #expect(store.state.amountText == formatter.string(from: NSDecimalNumber(decimal: maxZec)))
        // Explicitly NOT `simplified`: that would collapse 1.23456789 to 1.23 (and, for other
        // amounts, round UP past the spendable balance).
        #expect(store.state.amountText != formatter.string(from: NSDecimalNumber(decimal: maxZec.simplified)))
        #expect(!store.state.isMaxRequestInFlight)
    }

    @MainActor @Test func maxAmountResolvedFillsUsdEquivalentWhenInputIsInUsd() async {
        var state = swapState()
        state.isInputInUsd = true

        let store = TestStore(initialState: state) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.maxAmountResolved(Const.maxAmount))

        // 1.23456789 ZEC * $40 = $49.3827156, floored to cents ($49.38) — floored, so it can never
        // divide back into more ZEC than is spendable, and at cent precision because every other
        // USD figure on the Swap screen shows 2 decimals.
        let exactUsd = maxZec * Const.zecUsdPrice
        let expectedUsd = exactUsd.roundedDown(scale: 2)
        #expect(expectedUsd <= exactUsd)
        #expect(store.state.amountText == store.state.conversionFormatter.string(from: NSDecimalNumber(decimal: expectedUsd)))
    }

    // The max is a hard ceiling, so the fill must FLOOR, never round to nearest. Both amounts here
    // sit inside `simplified`'s 0.5% tolerance and would be taken UP past the max by it.
    @MainActor @Test func maxAmountResolvedNeverRoundsUpAboveTheMax() async {
        let zecStore = TestStore(initialState: swapState()) { SwapAndPay() }
        zecStore.exhaustivity = .off

        await zecStore.send(.maxAmountResolved(Const.roundsUpMaxAmount))

        let exactZec = Const.roundsUpMaxAmount.decimalValue.decimalValue
        #expect(exactZec.simplified > exactZec) // 1.996 -> 2.00: the hazard being guarded against
        #expect(zecStore.state.amountText == zecStore.state.conversionFormatter.string(from: NSDecimalNumber(decimal: exactZec)))

        var usdState = swapState()
        usdState.isInputInUsd = true
        let usdStore = TestStore(initialState: usdState) { SwapAndPay() }
        usdStore.exhaustivity = .off

        await usdStore.send(.maxAmountResolved(Const.usdRoundsUpMaxAmount))

        // $49.386 exactly: flooring to cents gives $49.38, `simplified` would give $49.39 — OVER the
        // max. The two differ here, which is what makes this value discriminating.
        let exactUsd = Const.usdRoundsUpMaxAmount.decimalValue.decimalValue * Const.zecUsdPrice
        #expect(exactUsd.simplified > exactUsd)
        #expect(usdStore.state.amountText == usdStore.state.conversionFormatter.string(from: NSDecimalNumber(decimal: exactUsd.roundedDown(scale: 2))))
        #expect(usdStore.state.amountText != usdStore.state.conversionFormatter.string(from: NSDecimalNumber(decimal: exactUsd.simplified)))
    }

    // The field parses its own text back, and it cannot parse grouping separators — so the fill
    // must use `conversionFormatter`/`conversionCrossPayFormatter`, never `formatter`. Below 1000
    // every formatter agrees, so this has to be asserted on a four-digit amount.
    @MainActor @Test func maxAmountResolvedNeverEmitsGroupingSeparators() async {
        let zecStore = TestStore(initialState: swapState()) { SwapAndPay() }
        zecStore.exhaustivity = .off

        await zecStore.send(.maxAmountResolved(Const.groupedMaxAmount))

        // 1234.5678 ZEC -> "1234.5678", not "1,234.5678".
        let exactZec = Const.groupedMaxAmount.decimalValue.decimalValue
        #expect(zecStore.state.amountText == zecStore.state.conversionFormatter.string(from: NSDecimalNumber(decimal: exactZec)))
        #expect(zecStore.state.amountText != zecStore.state.formatter.string(from: NSDecimalNumber(decimal: exactZec)))

        var usdState = swapState()
        usdState.isInputInUsd = true
        let usdStore = TestStore(initialState: usdState) { SwapAndPay() }
        usdStore.exhaustivity = .off

        await usdStore.send(.maxAmountResolved(Const.groupedMaxAmount))

        // 1234.5678 ZEC * $40 = $49382.712, floored to cents -> "49382.71", not "49,382.71".
        let expectedUsd = (exactZec * Const.zecUsdPrice).roundedDown(scale: 2)
        #expect(usdStore.state.amountText == usdStore.state.conversionFormatter.string(from: NSDecimalNumber(decimal: expectedUsd)))
        #expect(usdStore.state.amountText != usdStore.state.formatter.string(from: NSDecimalNumber(decimal: expectedUsd)))
    }

    // MARK: - .maxAmountResolved, Pay

    @MainActor @Test func maxAmountResolvedConvertsToTokenAndMirrorsSiblingFieldsInPayMode() async {
        let store = TestStore(initialState: payState()) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.maxAmountResolved(Const.maxAmount))

        // 1.23456789 ZEC * $40 / $2 = 24.6913578 BTC, worth $49.3827156.
        let formatter = store.state.conversionCrossPayFormatter
        let expectedToken = (maxZec * Const.zecUsdPrice / Const.tokenUsdPrice).roundedDown(scale: 8)
        // `payUsdLabel` derives the USD counterpart from the token field and applies NO `simplified`,
        // so the mirror must not either — otherwise tapping Max and typing the identical token
        // amount would leave different USD values on screen ($49.3827156 vs $49.38).
        let expectedUsd = expectedToken * Const.tokenUsdPrice

        #expect(store.state.amountAssetText == formatter.string(from: NSDecimalNumber(decimal: expectedToken)))
        // `amountText` carries the token amount for Pay — it is what `amount` and the
        // insufficient-funds check read — so it mirrors the asset field exactly.
        #expect(store.state.amountText == store.state.amountAssetText)
        #expect(store.state.amountUsdText == formatter.string(from: NSDecimalNumber(decimal: expectedUsd)))
        #expect(store.state.amountUsdText != formatter.string(from: NSDecimalNumber(decimal: expectedUsd.simplified)))
    }

    // Guarded against dividing by a missing price: do nothing rather than produce a bogus amount.
    @MainActor @Test func maxAmountResolvedDoesNothingInPayModeWhenSelectedAssetHasNoUsdPrice() async {
        var state = payState()
        state.selectedAsset = asset(token: "BTC", usdPrice: 0)

        let store = TestStore(initialState: state) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.maxAmountResolved(Const.maxAmount))

        #expect(store.state.amountAssetText.isEmpty)
        #expect(store.state.amountUsdText.isEmpty)
        #expect(store.state.amountText.isEmpty)
        #expect(!store.state.isMaxRequestInFlight)
    }

    @MainActor @Test func maxAmountResolvedDoesNothingInPayModeWhenZecAssetIsMissing() async {
        var state = payState()
        state.zecAsset = nil

        let store = TestStore(initialState: state) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.maxAmountResolved(Const.maxAmount))

        #expect(store.state.amountAssetText.isEmpty)
        #expect(store.state.amountText.isEmpty)
    }

    // MARK: - .maxAmountResolved, Swap token -> ZEC

    @MainActor @Test func maxAmountResolvedIsNoOpInSwapToZecMode() async {
        var state = swapState()
        state.isSwapToZecExperienceEnabled = true
        state.isMaxRequestInFlight = true

        let store = TestStore(initialState: state) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.maxAmountResolved(Const.maxAmount))

        #expect(store.state.amountText.isEmpty)
        #expect(!store.state.isMaxRequestInFlight)
    }

    // MARK: - Chip enablement

    @Test func swapMaxButtonEnablementReflectsSpendabilityAndInFlightRequests() {
        var state = swapState()
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        #expect(state.isSwapMaxButtonEnabled)

        state.walletBalancesState.spendability = .something
        #expect(state.isSwapMaxButtonEnabled)

        state.walletBalancesState.spendability = .nothing
        #expect(!state.isSwapMaxButtonEnabled)

        state.walletBalancesState.spendability = .everything
        state.isMaxRequestInFlight = true
        #expect(!state.isSwapMaxButtonEnabled)

        state.isMaxRequestInFlight = false
        state.isQuoteRequestInFlight = true
        #expect(!state.isSwapMaxButtonEnabled)

        state.isQuoteRequestInFlight = false

        // Empty wallet: `.everything` with zero balance must not enable the chip.
        state.walletBalancesState.shieldedBalance = .zero
        #expect(!state.isSwapMaxButtonEnabled)
        state.walletBalancesState.shieldedBalance = Zatoshi(500_000_000)

        state.$selectedWalletAccount.withLock { $0 = nil }
        #expect(!state.isSwapMaxButtonEnabled)
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }

        // USD input mode needs a usable ZEC price to convert the max.
        state.isInputInUsd = true
        state.zecAsset = asset(token: "ZEC", usdPrice: 0)
        #expect(!state.isSwapMaxButtonEnabled)
        state.zecAsset = nil
        #expect(!state.isSwapMaxButtonEnabled)
        state.zecAsset = asset(token: "ZEC", usdPrice: Const.zecUsdPrice)
        #expect(state.isSwapMaxButtonEnabled)
        state.isInputInUsd = false
    }

    // Pay needs the Swap conditions AND a usable price on both sides of the conversion.
    @Test func payMaxButtonEnablementAlsoRequiresUsablePrices() {
        var state = payState()
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        #expect(state.isPayMaxButtonEnabled)

        state.selectedAsset = asset(token: "BTC", usdPrice: 0)
        #expect(!state.isPayMaxButtonEnabled)

        state.selectedAsset = nil
        #expect(!state.isPayMaxButtonEnabled)

        state.selectedAsset = asset(token: "BTC", usdPrice: Const.tokenUsdPrice)
        state.zecAsset = nil
        #expect(!state.isPayMaxButtonEnabled)

        state.zecAsset = asset(token: "ZEC", usdPrice: Const.zecUsdPrice)
        state.walletBalancesState.spendability = .nothing
        #expect(!state.isPayMaxButtonEnabled)
    }
}
