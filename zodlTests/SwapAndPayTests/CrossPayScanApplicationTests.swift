//
//  CrossPayScanApplicationTests.swift
//  zodlTests
//
//  Covers SwapAndPay.State.applyScannedRequest (Features/SwapAndPayForm/SwapAndPayStore.swift):
//  what a scanned QR is allowed to change on the form. It is a `mutating func` on State rather
//  than a reducer case, so these drive State directly instead of through a TestStore.
//  NOTE: state.amount/assetAmount/usdAmount are _XCTIsTesting-poisoned to 0, so assertions go
//  through the raw *Text fields.
//

import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal

@Suite(.serialized) struct CrossPayScanApplicationTests {
    private enum Const {
        static let btcRequest = "bitcoin:1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo?amount=0.015"
        static let btcRequestNoAmount = "bitcoin:1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo"
        static let btcAddress = "1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo"
        static let recipient = "0x92bF6Fbd794bA41093013Db027400B174aE4b5Cd"
        static let usdcContract = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
    }

    // MARK: - Swap modes

    @Test func swapToZecKeepsTheRawScanAndNeverAdoptsAPaymentRequestRecipient() {
        // In Swap-to-ZEC `address` is the user's OWN refund address -- `getQuote` sends it as
        // `refundTo`, so a refunded swap goes there. Unwrapping a payment request's recipient into
        // it would hand a refund to a third party, and would do so with a clean, acceptable address
        // rather than a string the provider would reject.
        var state = payState()
        state.isSwapToZecExperienceEnabled = true
        state.address = "myOwnRefundAddress"
        state.selectedAsset = btcAsset

        state.applyScannedRequest(CrossPayRequestParser.parse(Const.btcRequest), rawValue: Const.btcRequest)

        #expect(state.address == Const.btcRequest)
        #expect(state.address != Const.btcAddress)
        #expect(state.amountAssetText.isEmpty)
    }

    @Test func swapModeKeepsTheRawScan() {
        var state = payState()
        state.isSwapExperienceEnabled = true

        state.applyScannedRequest(CrossPayRequestParser.parse(Const.btcRequest), rawValue: Const.btcRequest)

        #expect(state.address == Const.btcRequest)
    }

    // MARK: - Pay

    @Test func aPlainAddressStillLandsInTheAddressField() {
        var state = payState()

        state.applyScannedRequest(nil, rawValue: "bc1qplain")

        #expect(state.address == "bc1qplain")
    }

    @Test func aPaymentRequestFillsAddressAssetAndAmount() {
        var state = payState()
        state.selectedAsset = usdcAsset

        state.applyScannedRequest(CrossPayRequestParser.parse(Const.btcRequest), rawValue: Const.btcRequest)

        #expect(state.address == Const.btcAddress)
        #expect(state.selectedAsset == btcAsset)
        #expect(state.selectedContact == nil)
        #expect(state.amountAssetText == "0.015")
        #expect(state.amountText == "0.015")
    }

    @Test func anUnsupportedAssetChangesNothingAndReportsWhy() {
        // Native POL: the chain id maps, but no native POL asset is curated. Overwriting the form
        // here left a recipient address paired with whatever asset happened to be selected, and said
        // nothing about it.
        var state = payState()
        state.selectedAsset = usdcAsset
        state.address = "typedByHand"
        state.amountAssetText = "25"
        state.amountText = "25"

        let request = "ethereum:\(Const.recipient)@137?value=1e18"
        state.applyScannedRequest(CrossPayRequestParser.parse(request), rawValue: request)

        #expect(state.address == "typedByHand")
        #expect(state.selectedAsset == usdcAsset)
        #expect(state.amountAssetText == "25")
        #expect(state.toast == .top(String(localizable: .swapAndPayCrossPayAssetUnsupported)))
    }

    @Test func anUnparseableUriIsNotUnwrappedIntoTheAddressField() {
        // A Solana interactive transaction link parses as a request the app rejects, so it reaches
        // the form as a raw string -- `getQuote` would otherwise pass "solana:https://..." verbatim
        // as the destination. It is still visibly wrong in the field rather than silently sent.
        var state = payState()
        let link = "solana:https://example.com/pay"

        state.applyScannedRequest(CrossPayRequestParser.parse(link), rawValue: link)

        #expect(state.address == link)
    }

    // MARK: - Amount handling

    @Test func aRequestWithoutAnAmountKeepsWhatTheUserTypedForTheSameAsset() {
        // The common static shop QR. Clearing the field unconditionally threw away an amount the
        // user had already entered against the very asset the request names.
        var state = payState()
        state.selectedAsset = btcAsset
        state.amountAssetText = "25"
        state.amountText = "25"
        state.amountUsdText = "25"

        state.applyScannedRequest(
            CrossPayRequestParser.parse(Const.btcRequestNoAmount),
            rawValue: Const.btcRequestNoAmount
        )

        #expect(state.address == Const.btcAddress)
        #expect(state.amountAssetText == "25")
        #expect(state.amountText == "25")
    }

    @Test func aRequestWithoutAnAmountClearsAnAmountTypedAgainstADifferentAsset() {
        // The other half of the same rule: the number the user typed meant 25 USDC, and the asset
        // just moved to BTC underneath it.
        var state = payState()
        state.selectedAsset = usdcAsset
        state.amountAssetText = "25"
        state.amountText = "25"
        state.amountUsdText = "25"

        state.applyScannedRequest(
            CrossPayRequestParser.parse(Const.btcRequestNoAmount),
            rawValue: Const.btcRequestNoAmount
        )

        #expect(state.selectedAsset == btcAsset)
        #expect(state.amountAssetText.isEmpty)
        #expect(state.amountText.isEmpty)
        #expect(state.amountUsdText.isEmpty)
    }

    @Test func anOverPreciseAmountIsFlooredNeverRoundedUp() {
        // The formatter caps at 8 fraction digits with half-even rounding, and the string it
        // produces IS the amount that gets paid, so rounding to nearest could take
        // 1.999999999999999999 up to 2 and set the user up to overpay the request.
        var state = payState()
        state.selectedAsset = ethAsset

        let request = "ethereum:\(Const.recipient)@1?value=1999999999999999999"
        state.applyScannedRequest(CrossPayRequestParser.parse(request), rawValue: request)

        #expect(state.amountAssetText == "1.99999999")
        #expect(state.toast == .top(String(localizable: .swapAndPayCrossPayAmountRounded)))
    }

    @Test func anAmountBelowTheFieldsPrecisionIsRefusedRatherThanShownAsZero() {
        // 1 wei. Formatting it wrote a literal "0" into the amount field, which reads as a request
        // for nothing at all.
        var state = payState()
        state.selectedAsset = ethAsset
        state.amountAssetText = "25"

        let request = "ethereum:\(Const.recipient)@1?value=1"
        state.applyScannedRequest(CrossPayRequestParser.parse(request), rawValue: request)

        #expect(state.amountAssetText.isEmpty)
        #expect(state.amountText.isEmpty)
        #expect(state.toast == .top(String(localizable: .swapAndPayCrossPayAmountUnsupported)))
    }

    // MARK: - Fixtures

    private var btcAsset: SwapAsset {
        asset(token: "BTC", chain: "btc", decimals: 8)
    }

    private var ethAsset: SwapAsset {
        asset(token: "ETH", chain: "eth", decimals: 18)
    }

    private var usdcAsset: SwapAsset {
        asset(token: "USDC", chain: "base", decimals: 6, contractAddress: Const.usdcContract)
    }

    private func asset(
        token: String,
        chain: String,
        decimals: Int,
        contractAddress: String? = nil
    ) -> SwapAsset {
        SwapAsset(
            provider: "near",
            chain: chain,
            token: token,
            assetId: "\(chain).\(token)",
            contractAddress: contractAddress,
            usdPrice: 1,
            decimals: decimals
        )
    }

    /// Pay: both experience flags off, with the assets a request can resolve against loaded.
    private func payState() -> SwapAndPay.State {
        var state = SwapAndPay.State.initial
        state.isSwapExperienceEnabled = false
        state.isSwapToZecExperienceEnabled = false
        state.$swapAssets.withLock { $0 = [btcAsset, ethAsset, usdcAsset] }
        state.$toast.withLock { $0 = nil }
        return state
    }
}
