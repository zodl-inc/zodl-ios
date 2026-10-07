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
        // The host may be written without the `/` browsers insert before the fragment.
        #expect(GiftCardLink.isCandidate("https://gift.zodl.com#v=1&key=zgift1fixture&height=1"))
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

    @Test func rescannerForAnOpenedLinkKeepsScanAndPaste() {
        // A gift card link from outside the app only opens this scanner; it explains why the card
        // has to be scanned again and otherwise works like the regular one.
        let rescanner = Scan.State.giftCardRescanner
        #expect(rescanner.checkers == [.giftCardScanChecker])
        #expect(rescanner.isPasteEnabled)
        #expect(rescanner.instructions == String(localizable: .giftCardRescanInstructions))
        #expect(rescanner.instructions != Scan.State.giftCardScanner.instructions)
        #expect(GiftCardCoordFlow.State.rescanRequested.redeemState == nil)
        #expect(GiftCardCoordFlow.State.rescanRequested.scanState.instructions == rescanner.instructions)
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

    @Test(arguments: [false, true]) func swapCoordinatorRegistersGiftCardCheckerFirst(addressBook: Bool) {
        var state = SwapAndPayCoordFlow.State()
        if addressBook { state.path.append(.addressBook(AddressBook.State.initial)) }
        let store = Store(initialState: state) { SwapAndPayCoordFlow() }
        if addressBook {
            guard let id = store.withState({ $0.path.ids.last }) else {
                Issue.record("Address book entry missing")
                return
            }
            store.send(.path(.element(id: id, action: .addressBook(.scanButtonTapped))))
        } else {
            store.send(.swapAndPay(.scanTapped))
        }
        let checkers = store.withState { state -> [ScanCheckerWrapper]? in
            guard case .some(.scan(let scanState)) = state.path.last else { return nil }
            return scanState.checkers
        }
        #expect(checkers?.first == .giftCardScanChecker)
    }

    @Test(arguments: RootGiftCardRoutingTests.SwapScannerEntry.allCases)
    func swapCoordinatorKeepsOrdinaryAddressScanning(entry: RootGiftCardRoutingTests.SwapScannerEntry) async throws {
        var state = SwapAndPayCoordFlow.State()
        switch entry {
        case .form: break
        case .nestedForm: state.path.append(.swapAndPayForm(SwapAndPay.State.initial))
        case .addressBook: state.path.append(.addressBook(AddressBook.State.initial))
        }
        let store = Store(initialState: state) { SwapAndPayCoordFlow() }
        switch entry {
        case .form: store.send(.swapAndPay(.scanTapped))
        case .nestedForm:
            let id = try #require(store.withState { $0.path.ids.last })
            store.send(.path(.element(id: id, action: .swapAndPayForm(.scanTapped))))
        case .addressBook:
            let id = try #require(store.withState { $0.path.ids.last })
            store.send(.path(.element(id: id, action: .addressBook(.scanButtonTapped))))
        }
        state = store.withState { $0 }
        guard case .some(.scan(let scanState)) = state.path.last else {
            Issue.record("Scanner missing")
            return
        }
        let action = scanState.checkers.lazy.compactMap { $0.checker.checkQRCode("ordinary-address") }.first
        #expect(action == .foundString("ordinary-address"))
        let scanId = try #require(state.path.ids.last)
        // Exercise the coordinator's address consumer directly: its existing direct-scan pop
        // precedes the child reducer and produces a TCA missing-element warning in the full store.
        withDependencies {
            $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
        } operation: {
            _ = SwapAndPayCoordFlow().coordinatorReduce().reduce(
                into: &state, action: .path(.element(id: scanId, action: .scan(.foundString("ordinary-address"))))
            )
        }
        if entry == .form {
            #expect(state.swapAndPayState.address == "ordinary-address")
        } else {
            guard case .some(.addressBookContact(let contact)) = state.path.last else {
                Issue.record("Ordinary address did not reach the contact form")
                return
            }
            #expect(contact.address == "ordinary-address")
        }
    }

    // Omitting clear, or passing the trimmed action payload, leaves the consumed secret behind.
    @Test(arguments: [
        "https://gift.zodl.com/#v=1&key=synthetic-clipboard-fixture",
        "https://link.vizor.cash/payment-links/open#v3=synthetic-clipboard-fixture",
        "https://gift.zodl.com/#damaged"
    ])
    func pastedGiftClearsTheOriginalUntrimmedValue(link: String) async {
        let original = "  \(link)\n"
        let cleared = LockIsolated<[RedactableString]>([])
        let store = TestStore(initialState: Scan.State.giftCardScanner) { Scan() } withDependencies: {
            $0.giftCard = GiftCardClient.mock()
            $0.pasteboard = PasteboardClient(
                setString: { _ in },
                clearIfMatches: { value in cleared.withValue { $0.append(value) } },
                getString: { original.redacted }
            )
        }
        await store.send(.pasteTapped)
        await store.receive(.foundGiftCard(link.redacted)) { $0.isAnythingFound = true }
        await store.finish()
        #expect(cleared.value == [original.redacted])
    }

    @Test(arguments: ["ordinary-address", "unsupported", "", nil] as [String?])
    func nonGiftPasteDoesNotClearTheClipboard(text: String?) async {
        let cleared = LockIsolated<[RedactableString]>([])
        var state = Scan.State.giftCardScanner
        if text == "ordinary-address" { state.checkers.append(.swapStringScanChecker) }
        let store = TestStore(initialState: state) { Scan() } withDependencies: {
            $0.giftCard = GiftCardClient.mock()
            $0.mainQueue = .immediate
            $0.pasteboard = PasteboardClient(
                setString: { _ in },
                clearIfMatches: { value in cleared.withValue { $0.append(value) } },
                getString: { text?.redacted }
            )
        }
        if text == "ordinary-address" {
            await store.send(.pasteTapped)
            await store.receive(.foundString("ordinary-address")) { $0.isAnythingFound = true }
        } else {
            let reason: Scan.ScanImageResult = (text == nil || text == "") ? .nothingToPaste : .unsupportedPaste
            await store.send(.pasteTapped)
            await store.receive(.scanFailed(reason)) {
                $0.info = String(localizable: reason == .nothingToPaste ? .scanPasteEmpty : .scanPasteUnsupported)
            }
            await store.receive(.clearInfo) { $0.info = "" }
        }
        await store.finish()
        #expect(cleared.value.isEmpty)
    }

    @Test func cameraGiftScanDoesNotReadOrClearTheClipboard() async {
        let reads = LockIsolated(0)
        let cleared = LockIsolated<[RedactableString]>([])
        let store = TestStore(initialState: Scan.State.giftCardScanner) { Scan() } withDependencies: {
            $0.giftCard = GiftCardClient.mock()
            $0.pasteboard = PasteboardClient(
                setString: { _ in },
                clearIfMatches: { value in cleared.withValue { $0.append(value) } },
                getString: { reads.withValue { $0 += 1 }
                    return "replacement".redacted }
            )
        }
        await store.send(.scan(Self.zodlLink.redacted))
        await store.receive(.foundGiftCard(Self.zodlLink.redacted)) { $0.isAnythingFound = true }
        await store.finish()
        #expect(reads.value == 0)
        #expect(cleared.value.isEmpty)
    }

    @Test func pastedGiftCardLinkIsFound() async {
        var state = Scan.State.giftCardScanner
        state.instructions = nil
        let store = TestStore(initialState: state) {
            Scan()
        } withDependencies: {
            $0.giftCard = .mock()
            $0.pasteboard = PasteboardClient(setString: { _ in }, clearIfMatches: { _ in }, getString: { Self.vizorLink.redacted })
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
            $0.pasteboard = PasteboardClient(setString: { _ in }, clearIfMatches: { _ in }, getString: { "u1notagiftcard".redacted })
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
            $0.pasteboard = PasteboardClient(setString: { _ in }, clearIfMatches: { _ in }, getString: { nil })
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.pasteTapped)
        await store.receive(.scanFailed(.nothingToPaste)) {
            $0.info = String(localizable: .scanPasteEmpty)
        }
    }
}
