//
//  RootGiftCardRoutingTests.swift
//  zodlTests
//
//  How Root reaches the gift card flow: Home's entry point, a gift card scanned in the Scan or Send
//  flow, and a gift card link the app is opened with, which waits while the wallet is not on
//  screen or a payment flow is in progress, and opens once that clears. Leaving the flow always
//  closes the card's temporary wallet.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// `Root.State: Equatable` is provided test-target-wide by RootInitializeSDKHealTests.swift.
@Suite(.serialized) @MainActor struct RootGiftCardRoutingTests {
    private static let linkString = "https://gift.zodl.com/#v=1&key=zgifttest1fixture&height=3000000"

    private func makeStore(state: Root.State, cleaned: LockIsolated<[GiftCardHandle]> = LockIsolated([])) -> TestStore<Root.State, Root.Action> {
        let store = TestStore(initialState: state) {
            Root()
        } withDependencies: {
            var client = GiftCardClient.mock()
            client.cleanup = { handle in cleaned.withValue { $0.append(handle) } }
            $0.giftCard = client
            $0.exchangeRate = .noOp
            $0.sdkSynchronizer = .mocked()
            $0.mainQueue = .immediate
            $0.date.now = { Date(timeIntervalSince1970: 1_000_000) }
            $0.uriParser.checkRP = { _, _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    private func homeState() -> Root.State {
        var state = Root.State.initial
        state.destinationState.destination = .home
        state.splashAppeared = true
        return state
    }

    @Test func homeOpensTheScanner() async throws {
        let store = makeStore(state: homeState())

        await store.send(.home(.redeemGiftCardTapped))
        #expect(store.state.path == .giftCardCoordFlow)
        #expect(store.state.giftCardCoordFlowState.redeemState == nil)
        #expect(store.state.isSensitiveFlowActive)
    }

    @Test func openedLinkGoesStraightToTheCard() async throws {
        let store = makeStore(state: homeState())
        let url = try #require(URL(string: Self.linkString))

        await store.send(.destination(.deeplink(url)))
        #expect(store.state.path == .giftCardCoordFlow)
        #expect(store.state.giftCardCoordFlowState.redeemState?.link == Self.linkString.redacted)
        #expect(store.state.pendingGiftCardLink == nil)
        #expect(store.state.destinationState.destination == .home)
    }

    @Test func linkWaitsWhileAPaymentFlowIsOpenAndOpensAfterwards() async throws {
        var state = homeState()
        state.path = .sendCoordFlow
        let store = makeStore(state: state)
        let url = try #require(URL(string: Self.linkString))

        await store.send(.destination(.deeplink(url)))
        #expect(store.state.path == .sendCoordFlow)
        #expect(store.state.pendingGiftCardLink == Self.linkString.redacted)

        // Leaving the send flow clears the gate and the stashed link opens.
        await store.send(.sendCoordFlow(.sendForm(.dismissRequired)))
        #expect(store.state.path == .giftCardCoordFlow)
        #expect(store.state.giftCardCoordFlowState.redeemState?.link == Self.linkString.redacted)
        #expect(store.state.pendingGiftCardLink == nil)
    }

    @Test func linkWaitsUntilTheWalletIsOnScreen() async throws {
        var state = Root.State.initial
        state.splashAppeared = false
        let store = makeStore(state: state)
        let url = try #require(URL(string: Self.linkString))

        await store.send(.destination(.deeplink(url)))
        #expect(store.state.path == nil)
        #expect(store.state.pendingGiftCardLink == Self.linkString.redacted)
        #expect(!store.state.canOpenGiftCardFlow)
    }

    @Test func cardScannedInTheSendFlowOpensTheRedeemFlow() async throws {
        var state = homeState()
        state.path = .sendCoordFlow
        state.sendCoordFlowState.path.append(.scan(Scan.State.initial))
        let scanId = try #require(state.sendCoordFlowState.path.ids.last)
        let store = makeStore(state: state)

        await store.send(.sendCoordFlow(.path(.element(id: scanId, action: .scan(.foundGiftCard(Self.linkString.redacted))))))
        #expect(store.state.path == .giftCardCoordFlow)
        #expect(store.state.giftCardCoordFlowState.redeemState?.link == Self.linkString.redacted)
    }

    @Test func cardScannedInTheScanFlowOpensTheRedeemFlow() async {
        var state = homeState()
        state.path = .scanCoordFlow
        let store = makeStore(state: state)

        await store.send(.scanCoordFlow(.scan(.foundGiftCard(Self.linkString.redacted))))
        #expect(store.state.path == .giftCardCoordFlow)
        #expect(store.state.giftCardCoordFlowState.redeemState?.link == Self.linkString.redacted)
    }

    @Test func leavingTheFlowClosesTheCard() async {
        let handle = GiftCardHandle()
        let cleaned = LockIsolated<[GiftCardHandle]>([])
        var state = homeState()
        state.path = .giftCardCoordFlow
        state.giftCardCoordFlowState = GiftCardCoordFlow.State(link: Self.linkString.redacted)
        state.giftCardCoordFlowState.redeemState?.handle = handle
        state.giftCardCoordFlowState.redeemState?.step = .empty
        let store = makeStore(state: state, cleaned: cleaned)

        await store.send(.giftCardCoordFlow(.redeem(.closeTapped)))
        await store.receive(\.giftCardCoordFlow.redeem.delegate.dismiss)
        await store.receive(\.giftCardCoordFlow.cleanUp)
        await store.finish()

        #expect(store.state.path == nil)
        #expect(store.state.giftCardCoordFlowState.redeemState == nil)
        #expect(cleaned.value == [handle])
    }

    @Test func otherLinksKeepTheirBehaviour() async throws {
        let store = makeStore(state: homeState())
        let url = try #require(URL(string: "https://secant.flexa.link/whatever"))

        await store.send(.destination(.deeplink(url)))
        #expect(store.state.path == nil)
        #expect(store.state.pendingGiftCardLink == nil)
    }
}
