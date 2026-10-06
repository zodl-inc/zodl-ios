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
        linksRead: LockIsolated<[String]> = LockIsolated([]),
        leftoverSweeps: LockIsolated<Int> = LockIsolated(0),
        starts: LockIsolated<Int> = LockIsolated(0),
        start: (@Sendable () async -> Void)? = nil,
        stop: (@Sendable () -> Void)? = nil,
        stops: LockIsolated<Int> = LockIsolated(0),
        open: (@Sendable (String) async throws -> GiftCardHandle)? = nil,
        check: (@Sendable (GiftCardHandle) async throws -> zodl_internal.GiftCardStatus)? = nil,
        redeem: (@Sendable (GiftCardHandle, String) async throws -> String)? = nil,
        mainQueue: AnySchedulerOf<DispatchQueue> = .immediate
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
                return try await (open ?? mock.open)(link)
            }
            if let check { client.check = check }
            if let redeem { client.redeem = redeem }
            client.removeLeftoverWallets = { leftoverSweeps.withValue { $0 += 1 } }
            $0.giftCard = client
            $0.zcashSDKEnvironment = .live(network: ZcashNetworkBuilder.network(for: .mainnet))
            $0.exchangeRate = .noOp
            $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
            $0.sdkSynchronizer = .mocked(start: { _ in
                starts.withValue { $0 += 1 }
                await start?()
            }, stop: {
                stops.withValue { $0 += 1 }
                stop?()
            })
            $0.mainQueue = mainQueue
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

    @Test(arguments: [false, true]) func parentNavigationClosesTheCard(rescan: Bool) async {
        let handle = GiftCardHandle()
        let cleaned = LockIsolated<[GiftCardHandle]>([])
        let starts = LockIsolated(0)
        var state = homeState()
        state.path = .giftCardCoordFlow
        state.giftCardCoordFlowState = GiftCardCoordFlow.State(link: Self.linkString.redacted)
        state.giftCardCoordFlowState.redeemState?.handle = handle
        let store = makeStore(state: state, cleaned: cleaned, starts: starts)

        if rescan {
            await store.send(.deeplinkWarning(.rescanInZashi))
        } else {
            await store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: "fixture", isTorFailure: false))))
        }
        await store.finish()
        #expect(store.state.giftCardCoordFlowState.redeemState == nil)
        #expect(cleaned.value == [handle])
        #expect(starts.value == 1)
    }

    @Test func leavingWhileOpenIsSuspendedClosesItsLateHandle() async {
        let entered = GiftCardTestGate()
        let release = GiftCardTestGate()
        let returned = GiftCardTestGate()
        let handle = GiftCardHandle()
        let replacementHandle = GiftCardHandle()
        let originalLink = Self.linkString
        let cleaned = LockIsolated<[GiftCardHandle]>([])
        let stops = LockIsolated(0)
        var state = homeState()
        state.path = .giftCardCoordFlow
        state.giftCardCoordFlowState = GiftCardCoordFlow.State(link: Self.linkString.redacted)
        state.giftCardCoordFlowState.redeemState?.$selectedWalletAccount.withLock { $0 = nil }
        let store = makeStore(state: state, cleaned: cleaned, stops: stops, open: { link in
            if link != originalLink { return replacementHandle }
            await entered.open()
            await release.wait()
            await returned.open()
            return handle
        })
        await store.send(.giftCardCoordFlow(.redeem(.onAppear)))
        await entered.wait()
        await store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: nil, isTorFailure: false))))
        await store.send(.home(.redeemGiftCardTapped))
        await store.send(.giftCardCoordFlow(.scan(.foundGiftCard("https://gift.zodl.com/#replacement".redacted))))
        await store.send(.giftCardCoordFlow(.redeem(.onAppear)))
        await store.receive({ if case .giftCardCoordFlow(.redeem(.response(_, .statusLoaded))) = $0 { true } else { false } })
        await release.open()
        await returned.wait()
        await store.finish()
        #expect(store.state.giftCardCoordFlowState.redeemState?.handle == replacementHandle)
        #expect(cleaned.value == [handle])
        #expect(stops.value == 1)
    }

    @Test(arguments: [
        GiftCardRedeem.Action.Response.statusLoaded(.empty), .progressUpdated(0.7), .redeemSucceeded("old-tx"),
        .redeemFailed(.redeemFailed), .checkFailed(.checkFailed), .openFailed(.checkFailed), .autoRetryFired,
        .destinationResolved(AccountUUID(id: [UInt8](repeating: 0, count: 16)), "old-address".redacted)
    ]) func queuedOldResponseCannotMutateAReplacementVisit(response: GiftCardRedeem.Action.Response) async throws {
        var state = homeState()
        state.path = .giftCardCoordFlow
        state.giftCardCoordFlowState = GiftCardCoordFlow.State(link: Self.linkString.redacted)
        let oldVisit = try #require(state.giftCardCoordFlowState.redeemState?.cancelId)
        let store = makeStore(state: state)
        await store.send(.giftCardCoordFlow(.scan(.foundGiftCard("https://gift.zodl.com/#new".redacted))))
        await store.send(.giftCardCoordFlow(.redeem(.response(oldVisit, response))))
        #expect(store.state.giftCardCoordFlowState.redeemState?.step == .checking)
        #expect(store.state.giftCardCoordFlowState.redeemState?.destinationAddress == nil)
        #expect(store.state.giftCardCoordFlowState.redeemState?.txId == nil)
        #expect(store.state.giftCardCoordFlowState.redeemState?.syncProgress == nil)
    }

    @Test func staleOpenAfterStateRemovalClosesHandleWithoutStoppingSync() async {
        let handle = GiftCardHandle()
        let cleaned = LockIsolated<[GiftCardHandle]>([])
        let stops = LockIsolated(0)
        let store = makeStore(state: homeState(), cleaned: cleaned, stops: stops)
        await store.send(.giftCardCoordFlow(.redeem(.response(UUID(), .opened(handle)))))
        await store.finish()
        #expect(cleaned.value == [handle])
        #expect(stops.value == 0)
        #expect(store.state.path == nil)
    }

    @Test(arguments: [false, true]) func delayedWorkIsCancelledWhenAVisitIsReplaced(redeeming: Bool) async {
        let entered = GiftCardTestGate()
        let release = GiftCardTestGate()
        let returned = GiftCardTestGate()
        let cancelled = LockIsolated(false)
        let cleaned = LockIsolated<[GiftCardHandle]>([])
        let stops = LockIsolated(0)
        let handle = GiftCardHandle()
        let account = WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: 4, count: 16)), name: "Test", keySource: nil,
            seedFingerprint: nil, hdAccountIndex: Zip32AccountIndex(0), ufvk: nil, uivk: nil
        ))
        var state = homeState()
        state.path = .giftCardCoordFlow
        state.giftCardCoordFlowState = GiftCardCoordFlow.State(link: Self.linkString.redacted)
        state.giftCardCoordFlowState.redeemState?.handle = handle
        state.giftCardCoordFlowState.redeemState?.step = redeeming ? .ready(spendable: Zatoshi(10_000_000)) : .checkFailed
        state.giftCardCoordFlowState.redeemState?.destinationAddress = "utest1fixture".redacted
        state.giftCardCoordFlowState.redeemState?.destinationAccountId = account.id
        state.giftCardCoordFlowState.redeemState?.$selectedWalletAccount.withLock { $0 = account }
        let suspend: @Sendable () async -> Void = {
            await entered.open()
            await release.wait()
            cancelled.setValue(Task.isCancelled)
            await returned.open()
        }
        let store = makeStore(state: state, cleaned: cleaned, stops: stops,
            check: { _ in await suspend()
                return .empty
            }, redeem: { _, _ in await suspend()
                return "old-transaction"
            })
        await store.send(.giftCardCoordFlow(.redeem(redeeming ? .redeemTapped : .retryTapped)))
        if redeeming {
            await store.receive({
                if case .giftCardCoordFlow(.redeem(.response(_, .redemptionDestinationResolved))) = $0 { true } else { false }
            })
        }
        await entered.wait()
        await store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: nil, isTorFailure: false))))
        await store.send(.home(.redeemGiftCardTapped))
        await store.send(.giftCardCoordFlow(.scan(.foundGiftCard("https://gift.zodl.com/#replacement".redacted))))
        let replacement = store.state.giftCardCoordFlowState.redeemState
        await release.open()
        await returned.wait()
        await store.finish()
        #expect(cancelled.value)
        #expect(cleaned.value == [handle])
        #expect(stops.value == 0)
        #expect(store.state.giftCardCoordFlowState.redeemState == replacement)
    }

    @Test func suspendedResumeCannotLeaveSyncRunningAfterANewerCardOpens() async throws {
        let entered = GiftCardTestGate()
        let release = GiftCardTestGate()
        let returned = GiftCardTestGate()
        let syncing = LockIsolated(false)
        var state = homeState()
        state.path = .giftCardCoordFlow
        state.giftCardCoordFlowState = GiftCardCoordFlow.State(link: Self.linkString.redacted)
        state.giftCardCoordFlowState.redeemState?.handle = GiftCardHandle()
        let store = makeStore(state: state, start: {
            await entered.open()
            await release.wait()
            syncing.setValue(true)
            await returned.open()
        }, stop: { syncing.setValue(false) })
        await store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: nil, isTorFailure: false))))
        await store.receive(\.giftCardResumeSync)
        await entered.wait()
        await store.send(.home(.redeemGiftCardTapped))
        await store.send(.giftCardCoordFlow(.scan(.foundGiftCard(Self.linkString.redacted))))
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        await store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle())))))
        await store.receive({ if case .giftCardCoordFlow(.redeem(.response(_, .statusLoaded))) = $0 { true } else { false } })
        await release.open()
        await returned.wait()
        await store.finish()
        #expect(!syncing.value)
    }

    @Test func pendingRescanOpenedByOnChangeStillRetiresThePreviousCard() async {
        let handle = GiftCardHandle()
        let cleaned = LockIsolated<[GiftCardHandle]>([])
        let starts = LockIsolated(0)
        var state = homeState()
        state.path = .giftCardCoordFlow
        state.isGiftCardRescanPending = true
        state.giftCardCoordFlowState = GiftCardCoordFlow.State(link: Self.linkString.redacted)
        state.giftCardCoordFlowState.redeemState?.handle = handle
        let store = makeStore(state: state, cleaned: cleaned, starts: starts)
        await store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: nil, isTorFailure: false))))
        await store.finish()
        #expect(store.state.path == .giftCardCoordFlow)
        #expect(store.state.giftCardCoordFlowState.redeemState == nil)
        #expect(!store.state.isGiftCardRescanPending)
        #expect(cleaned.value == [handle])
        #expect(starts.value == 1)
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
        await store.finish()

        #expect(store.state.path == nil)
        #expect(store.state.giftCardCoordFlowState.redeemState == nil)
        #expect(cleaned.value == [handle])
    }

    /// Card wallets a killed or crashed run left behind are deleted when the app launches, before
    /// the rest of the start-up (held back here by a scheduler that never advances) can open one.
    @Test func launchRemovesLeftoverCardWallets() async {
        let leftoverSweeps = LockIsolated(0)
        let store = makeStore(state: .initial, leftoverSweeps: leftoverSweeps, mainQueue: DispatchQueue.test.eraseToAnyScheduler())

        await store.send(.initialization(.appDelegate(.didFinishLaunching)))
        for _ in 0..<100 where leftoverSweeps.value == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(leftoverSweeps.value == 1)

        await store.skipInFlightEffects(strict: false)
    }

    @Test func otherLinksKeepTheirBehaviour() async throws {
        let store = makeStore(state: homeState())
        let url = try #require(URL(string: "https://secant.flexa.link/whatever"))

        await store.send(.destination(.deeplink(url)))
        #expect(store.state.path == nil)
        #expect(!store.state.isGiftCardRescanPending)
    }
}
