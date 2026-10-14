//
//  GiftCardCoordFlowTests.swift
//  zodlTests
//
//  The gift card flow's navigation and lifetime: a scanned card replaces the scanner, and
//  internal replacement and `.cleanUp` close the card's temporary wallet. Root owns parent exits.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite(.serialized) @MainActor struct GiftCardCoordFlowTests {
    private static let link = "https://gift.zodl.com/#v=1&key=zgifttest1fixture&height=3000000".redacted

    @Test func pasteLinkOpensThePasteScreenAndContinueOpensTheCard() async {
        let link = Self.link
        let store = TestStore(initialState: GiftCardCoordFlow.State()) {
            GiftCardCoordFlow()
        } withDependencies: {
            $0.giftCard = .mock()
            $0.pasteboard = PasteboardClient(setString: { _ in }, clearIfMatches: { _ in }, getString: { link })
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.scan(.pasteTapped))
        #expect(store.state.pasteLinkState == GiftCardPasteLink.State())
        #expect(store.state.redeemState == nil)

        await store.send(.pasteLink(.pasteTapped))
        #expect(store.state.pasteLinkState?.isValid == true)

        await store.send(.pasteLink(.continueTapped))
        await store.receive(\.pasteLink.delegate.open)
        #expect(store.state.pasteLinkState == nil)
        #expect(store.state.redeemState?.link == Self.link)
        #expect(store.state.redeemState?.step == .checking)
    }

    @Test func backFromThePasteScreenReturnsToTheScanner() async {
        let store = TestStore(initialState: GiftCardCoordFlow.State()) {
            GiftCardCoordFlow()
        } withDependencies: {
            $0.giftCard = .mock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.scan(.pasteTapped))
        #expect(store.state.pasteLinkState != nil)

        await store.send(.pasteLink(.backTapped))
        await store.receive(\.pasteLink.delegate.back)
        #expect(store.state.pasteLinkState == nil)
        #expect(store.state.redeemState == nil)
        #expect(store.state.scanState.isPasteEnabled)
    }

    @Test func cleanUpClosesThePasteScreen() async {
        var state = GiftCardCoordFlow.State()
        state.pasteLinkState = GiftCardPasteLink.State()
        let store = TestStore(initialState: state) {
            GiftCardCoordFlow()
        } withDependencies: {
            $0.giftCard = .mock()
        }

        await store.send(.cleanUp) {
            $0.pasteLinkState = nil
        }
    }

    /// Cleanup while the paste screen holds a pasted card link clears it from the clipboard (if
    /// the clipboard still holds it), as leaving the screen does.
    @Test func cleanUpClearsALinkPastedOnThePasteScreen() async {
        let cleared = LockIsolated<[RedactableString]>([])
        var state = GiftCardCoordFlow.State()
        var paste = GiftCardPasteLink.State()
        paste.text = Self.link
        paste.clipboardCandidates = [Self.link]
        paste.isValid = true
        state.pasteLinkState = paste
        let store = TestStore(initialState: state) {
            GiftCardCoordFlow()
        } withDependencies: {
            $0.giftCard = .mock()
            $0.pasteboard = PasteboardClient(
                setString: { _ in },
                clearIfMatches: { value in cleared.withValue { $0.append(value) } },
                getString: { nil }
            )
        }

        await store.send(.cleanUp) {
            $0.pasteLinkState = nil
        }
        #expect(cleared.value == [Self.link])
    }

    @Test(arguments: [false, true])
    func editedKeyboardPasteIsClearedByStandaloneCoordinator(deleteField: Bool) async {
        let link = Self.link
        let clipboard = LockIsolated<(string: RedactableString?, reads: Int, writes: Int, candidates: [RedactableString])>(
            (link, 0, 0, [])
        )
        let store = TestStore(initialState: GiftCardCoordFlow.State()) {
            GiftCardCoordFlow()
        } withDependencies: {
            $0.giftCard = GiftCardClient.mock()
            $0.pasteboard = PasteboardClient(
                setString: { value in
                    clipboard.withValue {
                        $0.writes += 1
                        $0.string = value
                    }
                },
                clearIfMatches: { value in
                    clipboard.withValue {
                        $0.candidates.append(value)
                        if $0.string == value { $0.string = nil }
                    }
                },
                getString: {
                    clipboard.withValue {
                        $0.reads += 1
                        return $0.string
                    }
                }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.scan(.pasteTapped))
        await store.send(.pasteLink(.textChanged(Self.link)))
        await store.send(.pasteLink(.textChanged((deleteField ? "" : "ordinary replacement text").redacted)))
        #expect(clipboard.value.reads == 0)
        #expect(clipboard.value.writes == 0)
        #expect(clipboard.value.candidates.isEmpty)
        store.exhaustivity = .on
        await store.send(.cleanUp) {
            $0.pasteLinkState = nil
        }
        #expect(store.state.pasteLinkState == nil)
        #expect(store.state.redeemState == nil)
        #expect(clipboard.value.string == nil)
        #expect(clipboard.value.candidates == [Self.link])
        await store.send(.cleanUp)
        #expect(clipboard.value.candidates == [Self.link])
        #expect(clipboard.value.reads == 0)
        #expect(clipboard.value.writes == 0)
    }

    @Test func scannedCardOpensTheRedeemScreen() async {
        let store = TestStore(initialState: GiftCardCoordFlow.State()) {
            GiftCardCoordFlow()
        } withDependencies: {
            $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
            $0.giftCard = .mock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.scan(.foundGiftCard(Self.link)))
        #expect(store.state.scanState.isAnythingFound)
        #expect(store.state.redeemState?.link == Self.link)
        #expect(store.state.redeemState?.step == .checking)
    }

    @Test func cleanUpClosesTheOpenCardAndResetsTheFlow() async {
        let handle = GiftCardHandle()
        let cleaned = LockIsolated<[GiftCardHandle]>([])

        var state = GiftCardCoordFlow.State(link: Self.link)
        state.redeemState?.handle = handle
        state.redeemState?.step = .ready(redeemable: Zatoshi(10_000_000))

        let store = TestStore(initialState: state) {
            GiftCardCoordFlow()
        } withDependencies: {
            var client = GiftCardClient.mock()
            client.cleanup = { handle in cleaned.withValue { $0.append(handle) } }
            $0.giftCard = client
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.cleanUp) {
            $0.redeemState = nil
        }
        await store.finish()
        #expect(cleaned.value == [handle])
        #expect(store.state.scanState.checkers == [.giftCardScanChecker])
        #expect(store.state.scanState.isPasteEnabled)
    }

    @Test func replacingTheCardClosesThePreviousHandle() async {
        let handle = GiftCardHandle()
        let cleaned = LockIsolated<[GiftCardHandle]>([])
        var state = GiftCardCoordFlow.State(link: Self.link)
        state.redeemState?.handle = handle
        let store = TestStore(initialState: state) { GiftCardCoordFlow() } withDependencies: {
            var client = GiftCardClient.mock()
            client.cleanup = { handle in cleaned.withValue { $0.append(handle) } }
            $0.giftCard = client
            $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.scan(.foundGiftCard("https://gift.zodl.com/#replacement".redacted)))
        await store.finish()
        #expect(cleaned.value == [handle])
        #expect(store.state.redeemState?.handle == nil)
    }

    @Test func cleanUpWithNothingOpenDoesNothing() async {
        let store = TestStore(initialState: GiftCardCoordFlow.State()) {
            GiftCardCoordFlow()
        } withDependencies: {
            $0.giftCard = .mock()
        }

        await store.send(.cleanUp)
    }
}
