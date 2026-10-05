//
//  RootGiftCardRoutingTests.swift
//  zodlTests
//
//  How Root reaches the gift card flow: Home's entry point, a gift card scanned in the Scan or Send
//  flow, and a gift card link the app is opened with. Such a link is never used: it opens the
//  scanner asking for an in-app scan, waiting while the wallet is not on screen or a payment flow
//  is in progress, and opening once that clears. Leaving the flow always closes the card's
//  temporary wallet.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// `Root.State: Equatable` is provided test-target-wide by RootInitializeSDKHealTests.swift.
@Suite(.serialized) @MainActor struct RootGiftCardRoutingTests {
    private static let linkString = "https://gift.zodl.com/#v=1&key=zgifttest1fixture&height=3000000"

    private func makeStore(
        state: Root.State,
        cleaned: LockIsolated<[GiftCardHandle]> = LockIsolated([]),
        linksRead: LockIsolated<[String]> = LockIsolated([])
    ) -> TestStore<Root.State, Root.Action> {
        let store = TestStore(initialState: state) {
            Root()
        } withDependencies: {
            var client = GiftCardClient.mock()
            let mock = client
            client.cleanup = { handle in cleaned.withValue { $0.append(handle) } }
            client.parse = { link in
                linksRead.withValue { $0.append(link) }
                return try mock.parse(link)
            }
            client.open = { link in
                linksRead.withValue { $0.append(link) }
                return try await mock.open(link)
            }
            $0.giftCard = client
            $0.exchangeRate = .noOp
            $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
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

    @Test func openedLinkAsksForAnInAppScanAndIsNotUsed() async throws {
        let linksRead = LockIsolated<[String]>([])
        let store = makeStore(state: homeState(), linksRead: linksRead)
        let url = try #require(URL(string: Self.linkString))

        await store.send(.destination(.deeplink(url)))
        #expect(store.state.path == .giftCardCoordFlow)
        #expect(store.state.giftCardCoordFlowState.redeemState == nil)
        #expect(store.state.giftCardCoordFlowState.scanState.instructions == String(localizable: .giftCardRescanInstructions))
        #expect(!store.state.isGiftCardRescanPending)
        #expect(store.state.destinationState.destination == .home)
        await store.finish()
        #expect(linksRead.value.isEmpty)
    }

    @Test func openedLinkReplacesAnOpenCard() async throws {
        let handle = GiftCardHandle()
        let cleaned = LockIsolated<[GiftCardHandle]>([])
        var state = homeState()
        state.giftCardCoordFlowState = GiftCardCoordFlow.State(link: Self.linkString.redacted)
        state.giftCardCoordFlowState.redeemState?.handle = handle
        let store = makeStore(state: state, cleaned: cleaned)
        let url = try #require(URL(string: "https://gift.zodl.com/#v=1&key=zgifttest1other&height=3000000"))

        await store.send(.destination(.deeplink(url)))
        await store.finish()
        #expect(store.state.path == .giftCardCoordFlow)
        #expect(store.state.giftCardCoordFlowState.redeemState == nil)
        #expect(cleaned.value == [handle])
    }

    @Test func linkWaitsWhileAPaymentFlowIsOpenAndOpensAfterwards() async throws {
        var state = homeState()
        state.path = .sendCoordFlow
        let linksRead = LockIsolated<[String]>([])
        let store = makeStore(state: state, linksRead: linksRead)
        let url = try #require(URL(string: Self.linkString))

        await store.send(.destination(.deeplink(url)))
        #expect(store.state.path == .sendCoordFlow)
        #expect(store.state.isGiftCardRescanPending)

        // Leaving the send flow clears the gate and the scanner opens, not the card.
        await store.send(.sendCoordFlow(.sendForm(.dismissRequired)))
        #expect(store.state.path == .giftCardCoordFlow)
        #expect(store.state.giftCardCoordFlowState.redeemState == nil)
        #expect(store.state.giftCardCoordFlowState.scanState.instructions == String(localizable: .giftCardRescanInstructions))
        #expect(!store.state.isGiftCardRescanPending)
        await store.finish()
        #expect(linksRead.value.isEmpty)
    }

    @Test func linkWaitsUntilTheWalletIsOnScreen() async throws {
        var state = Root.State.initial
        state.splashAppeared = false
        let store = makeStore(state: state)
        let url = try #require(URL(string: Self.linkString))

        await store.send(.destination(.deeplink(url)))
        #expect(store.state.path == nil)
        #expect(store.state.isGiftCardRescanPending)
        #expect(!store.state.canOpenGiftCardFlow)
    }

    @Test func cardScannedAfterAnOpenedLinkOpensTheRedeemFlow() async throws {
        let store = makeStore(state: homeState())
        let url = try #require(URL(string: Self.linkString))
        let scanned = "https://gift.zodl.com/#v=1&key=zgifttest1scanned&height=3000000"

        await store.send(.destination(.deeplink(url)))
        await store.send(.giftCardCoordFlow(.scan(.foundGiftCard(scanned.redacted))))
        #expect(store.state.path == .giftCardCoordFlow)
        #expect(store.state.giftCardCoordFlowState.redeemState?.link == scanned.redacted)
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
        #expect(!store.state.isGiftCardRescanPending)
    }
}
