//
//  GiftCardScanTests.swift
//  zodlTests
//
//  Gift card links in the scanner: `GiftCardScanChecker` recognizes them (and only them), it runs
//  first wherever it is registered so `SwapStringScanChecker` (which accepts anything) can never
//  swallow a card, and "Paste link" runs the pasteboard through the same checkers.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@MainActor struct GiftCardScanTests {
    private static let zodlLink = "https://gift.zodl.com/#v=1&key=zgift1fixture&height=4453870&amount=0.1&desc=Welcome%20to%20Zcash%20Summit"
    private static let vizorLink = "https://link.vizor.cash/payment-links/open#v3=eyJmaXh0dXJlIjp0cnVlfQ"

    @Test func recognizesGiftCardLinks() {
        #expect(GiftCardLink.isCandidate(Self.zodlLink))
        #expect(GiftCardLink.isCandidate(Self.vizorLink))
        #expect(GiftCardLink.isCandidate("  HTTPS://GIFT.ZODL.COM/#v=1&key=zgift1fixture\n"))
    }

    @Test func ignoresEverythingElse() {
        #expect(!GiftCardLink.isCandidate("zcash:u1fixture?amount=1"))
        #expect(!GiftCardLink.isCandidate("u1fixtureaddress"))
        #expect(!GiftCardLink.isCandidate("https://zodl.com/"))
        #expect(!GiftCardLink.isCandidate("https://gift.zodl.com.evil.example/#v=1"))
        #expect(!GiftCardLink.isCandidate("http://gift.zodl.com/#v=1"))
        #expect(!GiftCardLink.isCandidate(""))
    }

    @Test func recognizesGiftCardURLsTheAppIsOpenedWith() throws {
        #expect(GiftCardLink.isGiftCardURL(try #require(URL(string: Self.zodlLink))))
        #expect(GiftCardLink.isGiftCardURL(try #require(URL(string: "https://gift.zodl.com/other"))))
        #expect(GiftCardLink.isGiftCardURL(try #require(URL(string: Self.vizorLink))))
        #expect(!GiftCardLink.isGiftCardURL(try #require(URL(string: "zcash:u1fixture"))))
        #expect(!GiftCardLink.isGiftCardURL(try #require(URL(string: "https://secant.flexa.link/x"))))
    }

    @Test func checkerReportsTheLinkRedacted() {
        let action = withDependencies {
            $0.giftCard = .mock()
        } operation: {
            GiftCardScanChecker().checkQRCode(Self.zodlLink)
        }
        #expect(action == .foundGiftCard(Self.zodlLink.redacted))
    }

    @Test func checkerIgnoresOtherCodes() {
        let action = withDependencies {
            $0.giftCard = .mock()
        } operation: {
            GiftCardScanChecker().checkQRCode("zcash:u1fixture?amount=1")
        }
        #expect(action == nil)
    }

    @Test func giftCardCheckerWinsOverTheCatchAllSwapChecker() async {
        var state = Scan.State.initial
        state.checkers = [.giftCardScanChecker, .swapStringScanChecker]
        let store = TestStore(initialState: state) {
            Scan()
        } withDependencies: {
            $0.giftCard = .mock()
        }

        await store.send(.scan(Self.zodlLink.redacted))
        await store.receive(.foundGiftCard(Self.zodlLink.redacted)) {
            $0.isAnythingFound = true
        }
    }

    @Test func scanFlowListsTheGiftCardCheckerFirst() async {
        // `ScanCoordFlow.State` is not Equatable, so this drives a plain `Store`.
        let store = Store(initialState: ScanCoordFlow.State()) {
            ScanCoordFlow()
        }
        store.send(.onAppear)
        #expect(store.withState(\.scanState.checkers).first == .giftCardScanChecker)

        // The send form's own Scan button inside the scan flow.
        store.send(.path(.push(id: 0, state: .sendForm(SendForm.State.initial))))
        store.send(.path(.element(id: 0, action: .sendForm(.scanTapped))))
        let pushed = store.withState { state -> [ScanCheckerWrapper]? in
            guard case .some(.scan(let scanState)) = state.path.last else { return nil }
            return scanState.checkers
        }
        #expect(pushed?.first == .giftCardScanChecker)

        #expect(Scan.State.giftCardScanner.checkers == [.giftCardScanChecker])
        #expect(Scan.State.giftCardScanner.isPasteEnabled)
    }

    @Test func sendFlowListsTheGiftCardCheckerFirst() async {
        // `SendCoordFlow.State` is not Equatable, so this drives a plain `Store`.
        let store = Store(initialState: SendCoordFlow.State()) {
            SendCoordFlow()
        }
        store.send(.sendForm(.scanTapped))
        let pushed = store.withState { state -> [ScanCheckerWrapper]? in
            guard case .some(.scan(let scanState)) = state.path.last else { return nil }
            return scanState.checkers
        }
        #expect(pushed?.first == .giftCardScanChecker)
    }

    @Test func pastedGiftCardLinkIsFound() async {
        var state = Scan.State.giftCardScanner
        state.instructions = nil
        let store = TestStore(initialState: state) {
            Scan()
        } withDependencies: {
            $0.giftCard = .mock()
            $0.pasteboard = PasteboardClient(setString: { _ in }, getString: { Self.vizorLink.redacted })
        }

        await store.send(.pasteTapped)
        await store.receive(.foundGiftCard(Self.vizorLink.redacted)) {
            $0.isAnythingFound = true
        }
    }

    @Test func pastingSomethingElseExplainsWhy() async {
        let store = TestStore(initialState: Scan.State.giftCardScanner) {
            Scan()
        } withDependencies: {
            $0.giftCard = .mock()
            $0.mainQueue = .immediate
            $0.pasteboard = PasteboardClient(setString: { _ in }, getString: { "u1notagiftcard".redacted })
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.pasteTapped)
        await store.receive(.scanFailed(.unsupportedPaste)) {
            $0.info = String(localizable: .scanPasteUnsupported)
        }
        #expect(!store.state.isAnythingFound)
    }

    @Test func pastingNothingExplainsWhy() async {
        let store = TestStore(initialState: Scan.State.giftCardScanner) {
            Scan()
        } withDependencies: {
            $0.giftCard = .mock()
            $0.mainQueue = .immediate
            $0.pasteboard = PasteboardClient(setString: { _ in }, getString: { nil })
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.pasteTapped)
        await store.receive(.scanFailed(.nothingToPaste)) {
            $0.info = String(localizable: .scanPasteEmpty)
        }
    }
}
