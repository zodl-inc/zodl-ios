//
//  GiftCardRedeemTests.swift
//  zodlTests
//
//  The redeem screen's state machine (`GiftCardRedeem`), driven through the mocked
//  `GiftCardClient`: checking → ready / pending / empty / errors, redeeming → success / failure,
//  and the destination being the selected account's Orchard-only address.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized: mutates the process-global `@Shared(.inMemory(.selectedWalletAccount))` slot.
@Suite(.serialized) @MainActor struct GiftCardRedeemTests {
    private static let link = "https://gift.zodl.com/#v=1&key=zgifttest1fixture&height=3000000&amount=0.1".redacted
    nonisolated(unsafe) private static let orchardUA = UnifiedAddress(validatedEncoding: "utest1orchardonlyfixture", networkType: .testnet)

    private var testWalletAccount: WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0, count: 16)),
                name: "Test",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private func makeStore(
        scenario: GiftCardClient.MockScenario,
        link: RedactableString = Self.link,
        withAccount: Bool = true,
        mainQueue: AnySchedulerOf<DispatchQueue> = .immediate,
        receivers: LockIsolated<[Set<ReceiverType>]> = LockIsolated([]),
        redeemedTo: LockIsolated<[String]> = LockIsolated([]),
        openCalls: LockIsolated<Int> = LockIsolated(0)
    ) -> TestStore<GiftCardRedeem.State, GiftCardRedeem.Action> {
        let state = GiftCardRedeem.State(link: link)
        let account = testWalletAccount
        state.$selectedWalletAccount.withLock { $0 = withAccount ? account : nil }

        var client = GiftCardClient.mock(scenario)
        let mockOpen = client.open
        client.open = { link in
            openCalls.withValue { $0 += 1 }
            return try await mockOpen(link)
        }
        let mockRedeem = client.redeem
        client.redeem = { handle, address in
            redeemedTo.withValue { $0.append(address) }
            return try await mockRedeem(handle, address)
        }

        let store = TestStore(initialState: state) {
            GiftCardRedeem()
        } withDependencies: {
            $0.giftCard = client
            $0.mainQueue = mainQueue
            $0.zcashSDKEnvironment = .testnet
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getCustomUnifiedAddress: { _, requested in
                    receivers.withValue { $0.append(requested) }
                    return Self.orchardUA
                }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    private func scenario(_ base: GiftCardClient.MockScenario) -> GiftCardClient.MockScenario {
        var scenario = base
        scenario.networkType = .testnet
        return scenario
    }

    @Test func readyCardIsRedeemedToTheOrchardOnlyAddress() async {
        let receivers = LockIsolated<[Set<ReceiverType>]>([])
        let redeemedTo = LockIsolated<[String]>([])
        let store = makeStore(scenario: scenario(.ready), receivers: receivers, redeemedTo: redeemedTo)

        await store.send(.onAppear)
        await store.receive(\.opened)
        await store.receive(\.statusLoaded) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
            $0.syncProgress = nil
        }
        #expect(store.state.summary?.message == "Welcome to Zcash Summit")
        #expect(store.state.isRedeemable)

        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive(\.redeemSucceeded) {
            $0.step = .success(amount: Zatoshi(10_000_000))
            $0.txId = GiftCardClient.MockScenario.ready.txId
        }
        await store.receive(\.delegate.redeemed)

        #expect(receivers.value.allSatisfy { $0 == [.orchard] })
        #expect(!receivers.value.isEmpty)
        #expect(redeemedTo.value == [Self.orchardUA.stringEncoded])
    }

    @Test func pendingCardChecksAgainOnItsOwn() async {
        let mainQueue = DispatchQueue.test
        let store = makeStore(scenario: scenario(.pending), mainQueue: mainQueue.eraseToAnyScheduler())

        await store.send(.onAppear)
        await store.receive(\.statusLoaded) {
            $0.step = .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 3)
        }
        #expect(!store.state.isRedeemable)

        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval))
        await store.receive(\.autoRetryFired) {
            $0.step = .checking
        }
        await store.receive(\.statusLoaded) {
            $0.step = .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 3)
        }

        await store.send(.closeTapped)
        await store.receive(\.delegate.dismiss)
        await store.finish()
    }

    @Test func emptyCardSaysSo() async {
        let store = makeStore(scenario: scenario(.empty))

        await store.send(.onAppear)
        await store.receive(\.statusLoaded) {
            $0.step = .empty
        }
        #expect(!store.state.isRedeemable)
        #expect(store.state.canRetry)
    }

    @Test func zeroSpendableIsTreatedAsEmpty() async {
        var base = scenario(.ready)
        base.status = .ready(spendable: .zero)
        let store = makeStore(scenario: base)

        await store.send(.onAppear)
        await store.receive(\.statusLoaded) {
            $0.step = .empty
        }
    }

    @Test func linkWithoutSecretIsInvalidAndNothingIsOpened() async {
        let openCalls = LockIsolated(0)
        let store = makeStore(scenario: scenario(.ready), link: "https://gift.zodl.com/".redacted, openCalls: openCalls)

        await store.send(.onAppear) {
            $0.step = .invalidLink
        }
        #expect(openCalls.value == 0)
    }

    @Test func cardForAnotherNetworkIsRejectedBeforeOpening() async {
        let openCalls = LockIsolated(0)
        var base = GiftCardClient.MockScenario.ready
        base.networkType = .mainnet
        let store = makeStore(scenario: base, openCalls: openCalls)

        await store.send(.onAppear) {
            $0.step = .wrongNetwork
            $0.summary = GiftCardSummary(
                origin: .zodl,
                networkType: .mainnet,
                birthdayHeight: 3_000_000,
                statedAmount: Zatoshi(10_000_000),
                message: "Welcome to Zcash Summit"
            )
        }
        #expect(openCalls.value == 0)
    }

    // MARK: - Live client (the wallet SDK's parser, offline)

    /// Vizor's published, never-funded mainnet reference vector (32 zero bytes of entropy).
    private static let vizorMainnetLink = [
        "https://link.vizor.cash/payment-links/open#v3=",
        "WyJtYWluIiwiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsMzQ4MzE0MSwiMTAwMDAwMCIsImtuaWdodE1hZ2ljIiwx",
        "MS4xNzQ3LCJJdCdzIGEgZ3JlYXQgZGF5IHRvIHNoaWVsZCB5b3VyIFpFQyDwn5uh77iPIl0"
    ].joined()

    private func liveStore(link: String) -> TestStore<GiftCardRedeem.State, GiftCardRedeem.Action> {
        let store = TestStore(initialState: GiftCardRedeem.State(link: link.redacted)) {
            GiftCardRedeem()
        } withDependencies: {
            $0.giftCard = .liveValue
            $0.zcashSDKEnvironment = .testnet
            $0.sdkSynchronizer = .mocked()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    @Test func liveClientReadsTheCardAndRejectsAnotherNetwork() async {
        let store = liveStore(link: Self.vizorMainnetLink)

        await store.send(.onAppear) {
            $0.summary = GiftCardSummary(
                origin: .vizor,
                networkType: .mainnet,
                birthdayHeight: 3_483_141,
                statedAmount: Zatoshi(1_000_000),
                message: "It's a great day to shield your ZEC 🛡️"
            )
            $0.step = .wrongNetwork
        }
    }

    @Test func liveClientReportsADamagedLink() async {
        let store = liveStore(link: Self.link.data)

        await store.send(.onAppear) {
            $0.step = .invalidLink
        }
    }

    @Test func liveClientReportsAnUnsupportedVersion() async {
        let store = liveStore(link: "https://gift.zodl.com/#v=2&key=zgifttest1fixture&height=3000000")

        await store.send(.onAppear) {
            $0.step = .unsupportedVersion
        }
    }

    @Test func liveClientReportsNotAGiftCardLink() async {
        let store = liveStore(link: "https://example.com/#v=1&key=zgifttest1fixture&height=3000000")

        await store.send(.onAppear) {
            $0.step = .invalidLink
        }
    }

    @Test func failedCheckCanBeRetried() async {
        let store = makeStore(scenario: scenario(.checkFails))

        await store.send(.onAppear)
        await store.receive(\.checkFailed) {
            $0.step = .checkFailed
        }
        #expect(store.state.canRetry)

        await store.send(.retryTapped) {
            $0.step = .checking
        }
        await store.receive(\.checkFailed) {
            $0.step = .checkFailed
        }
    }

    @Test func failedRedeemKeepsTheAmountAndRechecksOnRetry() async {
        let store = makeStore(scenario: scenario(.redeemFails))

        await store.send(.onAppear)
        await store.receive(\.statusLoaded) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
        }

        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive(\.redeemFailed) {
            $0.step = .failure(amount: Zatoshi(10_000_000))
        }

        // Retrying re-checks the card first: if the sweep did go through, it now reads empty.
        await store.send(.retryTapped) {
            $0.step = .checking
        }
        await store.receive(\.statusLoaded) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
        }
    }

    @Test func redeemIsUnavailableWithoutAnAccount() async {
        let store = makeStore(scenario: scenario(.ready), withAccount: false)

        await store.send(.onAppear)
        await store.receive(\.statusLoaded) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
        }
        #expect(!store.state.isRedeemable)

        await store.send(.redeemTapped)
        #expect(store.state.step == .ready(spendable: Zatoshi(10_000_000)))
    }

    @Test func closeAsksToDismiss() async {
        let store = makeStore(scenario: scenario(.ready))

        await store.send(.closeTapped)
        await store.receive(\.delegate.dismiss)
    }
}
