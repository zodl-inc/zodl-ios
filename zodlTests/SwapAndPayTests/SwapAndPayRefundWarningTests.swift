//
//  SwapAndPayRefundWarningTests.swift
//  zodlTests
//
//  Covers the sub-$300 refund warning (MOB-1889,
//  Features/SwapAndPayForm/SwapAndPayStore.swift): the `.getQuoteTapped` guard, the
//  per-surface suppression flags, and what Cancel / Continue persist.
//  NOTE: `usdAmount` is _XCTIsTesting-poisoned to 0, which is exactly why the threshold
//  reads `amount` (which has the `amountOverrideForTesting` seam) times the assets' own
//  `usdPrice` — so these tests drive real numbers rather than a constant zero.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

// Mutates process-global `@Shared` slots: the in-memory selected account and the three
// appStorage suppression flags.
@Suite(.serialized) struct SwapAndPayRefundWarningTests {
    private enum Const {
        static let zecUsdPrice = Decimal(40)
        static let tokenUsdPrice = Decimal(2)
        /// 7.5 ZEC at $40 is exactly $300 — the boundary the policy calls eligible.
        static let exactlyThresholdZec = Decimal(7.5)
        /// 7.4 ZEC at $40 is $296 — the first value under it.
        static let belowThresholdZec = Decimal(7.4)
        static let aboveThresholdZec = Decimal(10)
    }

    private func asset(token: String, usdPrice: Decimal) -> SwapAsset {
        SwapAsset(
            provider: "near",
            chain: token.lowercased(),
            token: token,
            assetId: "\(token)-id",
            usdPrice: usdPrice,
            decimals: 8
        )
    }

    /// Swap FROM ZEC: the amount is in ZEC, so the deposit value goes through the ZEC price.
    private func swapFromZecState(amount: Decimal) -> SwapAndPay.State {
        var state = SwapAndPay.State.initial
        state.isSwapExperienceEnabled = true
        state.isSwapToZecExperienceEnabled = false
        state.isInputInUsd = false
        state.amountOverrideForTesting = amount
        state.zecAsset = asset(token: "ZEC", usdPrice: Const.zecUsdPrice)
        state.selectedAsset = asset(token: "BTC", usdPrice: Const.tokenUsdPrice)
        return state
    }

    /// Swap TO ZEC: the deposit is the selected token, so its price is the multiplier.
    private func swapToZecState(amount: Decimal) -> SwapAndPay.State {
        var state = swapFromZecState(amount: amount)
        state.isSwapToZecExperienceEnabled = true
        return state
    }

    /// CrossPay: both experience flags off.
    private func crossPayState(amount: Decimal) -> SwapAndPay.State {
        var state = swapFromZecState(amount: amount)
        state.isSwapExperienceEnabled = false
        return state
    }

    /// The suppression flags are appStorage-backed and outlive a single test, and the
    /// selected account is a process-global `@Shared` slot other suites write to. Every test
    /// starts from a known state here and clears it again via `defer`.
    private func resetFlags(_ state: SwapAndPay.State) {
        state.$isRefundWarningSuppressedSwapToZec.withLock { $0 = false }
        state.$isRefundWarningSuppressedSwapFromZec.withLock { $0 = false }
        state.$isRefundWarningSuppressedCrossPay.withLock { $0 = false }
    }

    /// No selected account, so `.getQuoteTapped` takes its short path straight to `.getQuote`
    /// rather than the MOB-1803 rotation, which is covered by its own suite.
    private func prepared(_ state: SwapAndPay.State) -> SwapAndPay.State {
        state.$selectedWalletAccount.withLock { $0 = nil }
        resetFlags(state)
        return state
    }

    // MARK: - Surface resolution

    // Two booleans encode three surfaces and `isSwapExperienceEnabled` defaults to true, so
    // the TO-ZEC flag has to win regardless of it.
    @MainActor @Test func surfaceResolvesAllThreeForms() {
        #expect(swapFromZecState(amount: 1).refundWarningSurface == .swapFromZec)
        #expect(swapToZecState(amount: 1).refundWarningSurface == .swapToZec)
        #expect(crossPayState(amount: 1).refundWarningSurface == .crossPay)

        var bothFlags = swapToZecState(amount: 1)
        bothFlags.isSwapExperienceEnabled = true
        #expect(bothFlags.refundWarningSurface == .swapToZec)
    }

    // MARK: - The threshold

    @MainActor @Test func warningShownBelowThreshold() async {
        let state = prepared(swapFromZecState(amount: Const.belowThresholdZec))
        defer { resetFlags(state) }

        let store = TestStore(initialState: state) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.getQuoteTapped(skipRefundWarning: false)) {
            $0.isRefundWarningPresented = true
        }
        await store.finish()

        #expect(store.state.isRefundWarningPresented)
    }

    // "$300 or more" is eligible, so the boundary itself must go straight through.
    @MainActor @Test func noWarningAtExactlyThreshold() async {
        let state = prepared(swapFromZecState(amount: Const.exactlyThresholdZec))
        defer { resetFlags(state) }

        #expect(state.refundWarningDepositUsd == 300)
        #expect(!state.isBelowRefundThreshold)

        let store = TestStore(initialState: state) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.getQuoteTapped(skipRefundWarning: false))
        await store.receive(\.getQuote)
        await store.finish()

        #expect(!store.state.isRefundWarningPresented)
    }

    @MainActor @Test func noWarningAboveThreshold() async {
        let state = prepared(swapFromZecState(amount: Const.aboveThresholdZec))
        defer { resetFlags(state) }

        let store = TestStore(initialState: state) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.getQuoteTapped(skipRefundWarning: false))
        await store.receive(\.getQuote)
        await store.finish()

        #expect(!store.state.isRefundWarningPresented)
    }

    // Each surface measures a different field in a different unit.
    @MainActor @Test func depositValueUsesTheRightPricePerSurface() {
        // FROM ZEC: 7.4 ZEC * $40 = $296
        #expect(swapFromZecState(amount: Const.belowThresholdZec).refundWarningDepositUsd == 296)
        // TO ZEC and CrossPay: 7.4 tokens * $2 = $14.8
        #expect(swapToZecState(amount: Const.belowThresholdZec).refundWarningDepositUsd == Decimal(14.8))
        #expect(crossPayState(amount: Const.belowThresholdZec).refundWarningDepositUsd == Decimal(14.8))

        // USD input mode: the entered figure is already the deposit value.
        var usdInput = swapFromZecState(amount: 250)
        usdInput.isInputInUsd = true
        #expect(usdInput.refundWarningDepositUsd == 250)
        #expect(usdInput.isBelowRefundThreshold)
    }

    // Unreachable through the UI (`isValidForm` needs an asset), but if it ever happens the
    // safe answer is to warn rather than let a swap through unwarned.
    @MainActor @Test func missingPriceFailsSafeToWarning() {
        var noAssets = SwapAndPay.State.initial
        noAssets.amountOverrideForTesting = Decimal(1000)
        #expect(noAssets.refundWarningDepositUsd == nil)
        #expect(noAssets.isBelowRefundThreshold)
    }

    // MARK: - Suppression

    @MainActor @Test func suppressedSurfaceSkipsTheWarning() async {
        let state = prepared(swapFromZecState(amount: Const.belowThresholdZec))
        defer { resetFlags(state) }

        state.$isRefundWarningSuppressedSwapFromZec.withLock { $0 = true }

        let store = TestStore(initialState: state) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.getQuoteTapped(skipRefundWarning: false))
        await store.receive(\.getQuote)
        await store.finish()

        #expect(!store.state.isRefundWarningPresented)
    }

    // Product asked for per-surface flags: silencing Swap must not silence CrossPay.
    @MainActor @Test func suppressionDoesNotLeakAcrossSurfaces() async {
        let state = prepared(crossPayState(amount: Const.belowThresholdZec))
        defer { resetFlags(state) }

        state.$isRefundWarningSuppressedSwapFromZec.withLock { $0 = true }
        state.$isRefundWarningSuppressedSwapToZec.withLock { $0 = true }

        let store = TestStore(initialState: state) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.getQuoteTapped(skipRefundWarning: false)) {
            $0.isRefundWarningPresented = true
        }
        await store.finish()

        #expect(store.state.isRefundWarningPresented)
    }

    // MARK: - Cancel / Continue

    @MainActor @Test func cancelPersistsNothingAndSubmitsNothing() async {
        let state = prepared(swapFromZecState(amount: Const.belowThresholdZec))
        defer { resetFlags(state) }

        let store = TestStore(initialState: state) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.getQuoteTapped(skipRefundWarning: false))
        await store.send(.binding(.set(\.refundWarningDontShowAgain, true)))
        await store.send(.refundWarningCancelTapped)
        await store.finish()

        #expect(!store.state.isRefundWarningPresented)
        #expect(!store.state.refundWarningDontShowAgain)
        // Ticking the box and then cancelling must not silence anything.
        #expect(!store.state.isRefundWarningSuppressedSwapFromZec)
    }

    @MainActor @Test func continueProceedsWithoutPersistingWhenBoxUnchecked() async {
        let state = prepared(swapFromZecState(amount: Const.belowThresholdZec))
        defer { resetFlags(state) }

        let store = TestStore(initialState: state) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.getQuoteTapped(skipRefundWarning: false))
        await store.send(.refundWarningContinueTapped)
        await store.receive(\.getQuoteTapped)
        await store.receive(\.getQuote)
        await store.finish()

        #expect(!store.state.isRefundWarningPresented)
        #expect(!store.state.isRefundWarningSuppressedSwapFromZec)
    }

    @MainActor @Test func continueWithBoxCheckedPersistsAndProceeds() async {
        let state = prepared(swapFromZecState(amount: Const.belowThresholdZec))
        defer { resetFlags(state) }

        let store = TestStore(initialState: state) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.getQuoteTapped(skipRefundWarning: false))
        await store.send(.binding(.set(\.refundWarningDontShowAgain, true)))
        await store.send(.refundWarningContinueTapped)
        await store.receive(\.getQuoteTapped)
        await store.receive(\.getQuote)
        await store.finish()

        #expect(store.state.isRefundWarningSuppressedSwapFromZec)
        // Only this surface.
        #expect(!store.state.isRefundWarningSuppressedCrossPay)
        #expect(!store.state.isRefundWarningSuppressedSwapToZec)
    }

    // Continue re-enters `.getQuoteTapped`; without the skip it would re-arm the sheet and
    // the user could never get past it.
    @MainActor @Test func skipRefundWarningBypassesTheGuardEntirely() async {
        let state = prepared(swapFromZecState(amount: Const.belowThresholdZec))
        defer { resetFlags(state) }

        let store = TestStore(initialState: state) { SwapAndPay() }
        store.exhaustivity = .off

        await store.send(.getQuoteTapped(skipRefundWarning: true))
        await store.receive(\.getQuote)
        await store.finish()

        #expect(!store.state.isRefundWarningPresented)
    }
}
