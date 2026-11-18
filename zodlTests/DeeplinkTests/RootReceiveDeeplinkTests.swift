//
//  RootReceiveDeeplinkTests.swift
//  zodlTests
//
//  How Root handles a `zcash:///home/receive` link the app is opened with.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

// `Root.State: Equatable` is provided test-target-wide by RootInitializeSDKHealTests.swift.
@Suite(.serialized) @MainActor struct RootReceiveDeeplinkTests {
    private static let receiveURL = URL(string: "zcash:///home/receive")!

    // A fresh in-memory storage keeps a `selectedWalletAccount` written by other suites out of these tests.
    private func makeStore(
        destination: Root.DestinationState.Destination = .welcome,
        splashAppeared: Bool = false,
        path: Root.State.Path? = nil
    ) -> TestStore<Root.State, Root.Action> {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.destinationState.destination = destination
            state.splashAppeared = splashAppeared
            state.path = path
            let store = TestStore(initialState: state) {
                Root()
            } withDependencies: {
                $0.deeplink = .live()
                $0.derivationTool = .noOp
                $0.uriParser.checkRP = { _, _ in nil }
                $0.zcashSDKEnvironment = .live(network: ZcashNetworkBuilder.network(for: .mainnet))
            }
            store.exhaustivity = .off(showSkippedAssertions: false)
            return store
        }
    }

    @Test func linkOpensReceiveFromHome() async {
        let store = makeStore(destination: .home, splashAppeared: true)

        await store.send(.destination(.deeplink(Self.receiveURL)))
        await store.receive(\.home.receiveTapped)
        #expect(store.state.path == .receive)
    }

    @Test func linkIsIgnoredWhileAFlowIsOpen() async {
        let store = makeStore(destination: .home, splashAppeared: true, path: .sendCoordFlow)

        await store.send(.destination(.deeplink(Self.receiveURL)))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.path == .sendCoordFlow)
        #expect(!store.state.isReceiveDeeplinkPending)
    }

    @Test func linkWaitsForLaunchAndOpensOnceHomeIsUnlocked() async {
        let store = makeStore()

        await store.send(.destination(.deeplink(Self.receiveURL)))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.isReceiveDeeplinkPending)

        await store.send(.destination(.updateDestination(.home)))
        #expect(store.state.path == nil)

        await store.send(.splashFinished)
        await store.receive(\.home.receiveTapped)
        #expect(store.state.path == .receive)
        #expect(!store.state.isReceiveDeeplinkPending)
    }

    @Test func linkIsDroppedWhenThereIsNoWallet() async {
        let store = makeStore()

        await store.send(.destination(.deeplink(Self.receiveURL)))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.isReceiveDeeplinkPending)

        await store.send(.destination(.updateDestination(.onboarding)))
        #expect(!store.state.isReceiveDeeplinkPending)

        await store.send(.destination(.updateDestination(.home)))
        await store.send(.splashFinished)
        await store.skipReceivedActions(strict: false)
        #expect(store.state.path == nil)
    }

    @Test(arguments: ["https://secant.flexa.link/explore", "zcash:///home/receive/extra"])
    func linksThatAreNotOursRaiseNoAlert(_ link: String) async throws {
        let store = makeStore(destination: .home, splashAppeared: true)
        let url = try #require(URL(string: link))

        await store.send(.destination(.deeplink(url)))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.alert == nil)
        #expect(store.state.path == nil)
    }
}
