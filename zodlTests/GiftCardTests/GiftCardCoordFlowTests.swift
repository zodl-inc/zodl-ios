//
//  GiftCardCoordFlowTests.swift
//  zodlTests
//
//  The gift card flow's navigation and lifetime: a scanned card replaces the scanner, and
//  `.cleanUp` (sent by Root on every exit) closes the card's temporary wallet and resets the flow.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct GiftCardCoordFlowTests {
    private static let link = "https://gift.zodl.com/#v=1&key=zgifttest1fixture&height=3000000".redacted

    @Test func pastedLinkOpensTheRedeemScreen() async {
        let store = TestStore(initialState: GiftCardCoordFlow.State()) {
            GiftCardCoordFlow()
        } withDependencies: {
            $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
            $0.giftCard = .mock()
            $0.pasteboard.getString = { Self.link }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.scan(.pasteTapped))
        await store.receive(\.scan.foundGiftCard)
        #expect(store.state.redeemState?.link == Self.link)
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
        state.redeemState?.step = .ready(spendable: Zatoshi(10_000_000))

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

    @Test func cleanUpWithNothingOpenDoesNothing() async {
        let store = TestStore(initialState: GiftCardCoordFlow.State()) {
            GiftCardCoordFlow()
        } withDependencies: {
            $0.giftCard = .mock()
        }

        await store.send(.cleanUp)
    }
}
