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

// Serialized: mutates the process-global selected-account and exchange-rate `@Shared` slots.
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
        await store.receive({ if case .response(_, .opened) = $0 { true } else { false } })
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
            $0.syncProgress = nil
        }
        #expect(store.state.summary?.message == "Welcome to Zcash Summit")
        #expect(store.state.isRedeemable)

        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive({ if case .response(_, .redeemSucceeded) = $0 { true } else { false } }) {
            $0.step = .success
            $0.txId = GiftCardClient.MockScenario.ready.txId
        }
        await store.receive(\.delegate.redeemed)

        #expect(receivers.value.allSatisfy { $0 == [.orchard] })
        #expect(!receivers.value.isEmpty)
        #expect(redeemedTo.value == [Self.orchardUA.stringEncoded])
    }

    @Test func successfulRedeemKeepsTheTransactionIdWithoutReportingThePreFeeAmount() async {
        var card = scenario(.ready)
        card.txId = "redeemed-tx"
        let store = makeStore(scenario: card)
        store.state.$currencyConversion.withLock { $0 = CurrencyConversion(.usd, ratio: 30, timestamp: 0) }
        defer { store.state.$currencyConversion.withLock { $0 = nil } }

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } })
        #expect(store.state.step == .ready(spendable: Zatoshi(10_000_000)))
        #expect(store.state.amount == Zatoshi(10_000_000))
        #expect(store.state.fiatAmount != nil)

        await store.send(.redeemTapped)
        #expect(store.state.step == .redeeming(amount: Zatoshi(10_000_000)))
        #expect(store.state.amount == Zatoshi(10_000_000))
        await store.receive({ if case .response(_, .redeemSucceeded) = $0 { true } else { false } })
        await store.receive(\.delegate.redeemed)
        await store.finish()

        #expect(store.state.step == .success)
        #expect(store.state.txId == "redeemed-tx")
        #expect(store.state.amount == nil)
        #expect(store.state.fiatAmount == nil)
    }

    @Test func pendingCardChecksAgainOnItsOwn() async {
        let mainQueue = DispatchQueue.test
        let store = makeStore(scenario: scenario(.pending), mainQueue: mainQueue.eraseToAnyScheduler())

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 3)
        }
        #expect(!store.state.isRedeemable)

        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval))
        await store.receive({ if case .response(_, .autoRetryFired) = $0 { true } else { false } }) {
            $0.step = .checking
        }
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 3)
        }

        await store.send(.closeTapped)
        await store.receive(\.delegate.dismiss)
        await store.finish()
    }

    @Test func emptyCardSaysSo() async {
        let store = makeStore(scenario: scenario(.empty))

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
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
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
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

    /// The legacy reference vector above with its birthday moved to height 1, before the card's pool
    /// existed: syncing from there would scan the whole chain for nothing.
    private static let legacyLowBirthdayLink = [
        "\(GiftCardLink.vizorPrefix)#v3=",
        "WyJtYWluIiwiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsMSwiMTAwMDAwMCIsImtuaWdodE1hZ2ljIiwx",
        "MS4xNzQ3LCJJdCdzIGEgZ3JlYXQgZGF5IHRvIHNoaWVsZCB5b3VyIFpFQyDwn5uh77iPIl0"
    ].joined()

    @Test func liveClientReportsAnImpossibleBirthdayAsAnInvalidCard() async {
        #expect(throws: ZcashError.giftCardLinkInvalidBirthday) {
            _ = try GiftCard(link: Self.legacyLowBirthdayLink)
        }
        #expect(throws: GiftCardClientError.invalidLink) {
            _ = try GiftCardClient.parseCard(Self.legacyLowBirthdayLink)
        }

        let store = liveStore(link: Self.legacyLowBirthdayLink)
        await store.send(.onAppear) {
            $0.step = .invalidLink
        }
    }

    @Test func liveClientMapsEachTypedLinkError() {
        #expect(GiftCardClient.parseError(ZcashError.giftCardLinkNotAGiftCard) == .notAGiftCardLink)
        #expect(GiftCardClient.parseError(ZcashError.giftCardLinkUnsupportedVersion) == .unsupportedVersion)
        #expect(GiftCardClient.parseError(ZcashError.giftCardLinkUnsupportedNetwork) == .networkMismatch)
        #expect(GiftCardClient.parseError(ZcashError.giftCardLinkInvalidBirthday) == .invalidLink)
        #expect(GiftCardClient.parseError(ZcashError.giftCardLinkInvalid) == .invalidLink)
        #expect(GiftCardClient.parseError(CancellationError()) == .invalidLink)
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
        await store.receive({ if case .response(_, .checkFailed) = $0 { true } else { false } }) {
            $0.step = .checkFailed
        }
        #expect(store.state.canRetry)

        await store.send(.retryTapped) {
            $0.step = .checking
        }
        await store.receive({ if case .response(_, .checkFailed) = $0 { true } else { false } }) {
            $0.step = .checkFailed
        }
    }

    /// The card held too little to pay the fee (or was redeemed elsewhere) by the time it was
    /// swept: nothing was sent, so the screen says there is nothing to redeem instead of offering
    /// a Retry that would fail the same way.
    @Test func nothingToRedeemOnRedeemShowsTheEmptyCard() async {
        let store = makeStore(scenario: scenario(GiftCardClient.MockScenario(redeemError: .nothingToRedeem)))

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
        }
        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive({ if case .response(_, .redeemFailed) = $0 { true } else { false } }) {
            $0.step = .empty
        }
        #expect(!store.state.isRedeemable)
    }

    @Test(arguments: [
        ("en", "Redemption not confirmed", "We couldn't confirm redemption. Tap Try again to check the card's current status."),
        ("es", "Canje no confirmado", "No pudimos confirmar el canje. Pulsa Intentar de nuevo para comprobar el estado actual de la tarjeta.")
    ])
    func failedRedemptionCopyDoesNotClaimTheFundsStayedOnTheCard(language: String, title: String, description: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: "giftCard.failure.title", value: nil, table: "Localizable") == title)
        #expect(bundle.localizedString(forKey: "giftCard.failure.desc", value: nil, table: "Localizable") == description)
    }

    @Test func ambiguousSubmissionRechecksEmptyWithoutAnotherBroadcast() async {
        let redeemedTo = LockIsolated<[String]>([])
        let checks = LockIsolated(0)
        let state = GiftCardRedeem.State(link: Self.link)
        let previousAccount = state.selectedWalletAccount
        state.$selectedWalletAccount.withLock { $0 = testWalletAccount }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }
        var client = GiftCardClient.mock(scenario(.redeemFails))
        client.check = { _ in
            checks.withValue { count in
                count += 1
                return count == 1 ? .ready(spendable: Zatoshi(10_000_000)) : .empty
            }
        }
        client.redeem = { _, address in
            redeemedTo.withValue { $0.append(address) }
            throw GiftCardClientError.redeemFailed
        }
        let store = TestStore(initialState: state) { GiftCardRedeem() } withDependencies: {
            $0.giftCard = client
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment = .testnet
            $0.sdkSynchronizer = .mocked(getCustomUnifiedAddress: { _, _ in Self.orchardUA })
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } })
        #expect(store.state.step == .ready(spendable: Zatoshi(10_000_000)))
        await store.send(.redeemTapped)
        await store.receive({ if case .response(_, .redeemFailed) = $0 { true } else { false } })
        #expect(store.state.step == .failure(amount: Zatoshi(10_000_000)))
        #expect(store.state.txId == nil)

        await store.send(.retryTapped)
        #expect(store.state.step == .checking)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } })
        await store.finish()
        #expect(store.state.step == .empty)
        #expect(store.state.txId == nil)
        #expect(checks.value == 2)
        #expect(redeemedTo.value == [Self.orchardUA.stringEncoded])
    }

    @Test func failedRedeemKeepsTheAmountAndRechecksOnRetry() async {
        let store = makeStore(scenario: scenario(.redeemFails))

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
        }

        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive({ if case .response(_, .redeemFailed) = $0 { true } else { false } }) {
            $0.step = .failure(amount: Zatoshi(10_000_000))
        }

        // Retrying re-checks the card first: if the sweep did go through, it now reads empty.
        await store.send(.retryTapped) {
            $0.step = .checking
        }
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
        }
    }

    /// A broadcast that fails once: Retry re-checks the card through the handle it already has
    /// (the client swaps the card's wallet underneath it), finds the funds still there, and the
    /// next tap sweeps them.
    @Test func retryAfterAFailedRedeemChecksTheSameCardAndThenSucceeds() async {
        let openCalls = LockIsolated(0)
        let redeemedTo = LockIsolated<[String]>([])
        let store = makeStore(scenario: scenario(.redeemFailsOnce), redeemedTo: redeemedTo, openCalls: openCalls)

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .opened) = $0 { true } else { false } })
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
        }
        let handle = store.state.handle

        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive({ if case .response(_, .redeemFailed) = $0 { true } else { false } }) {
            $0.step = .failure(amount: Zatoshi(10_000_000))
        }
        #expect(store.state.canRetry)

        await store.send(.retryTapped) {
            $0.step = .checking
        }
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
        }
        #expect(store.state.handle == handle)
        #expect(openCalls.value == 1)
        await store.finish()
        #expect(store.state.txId == nil)
        #expect(redeemedTo.value == [Self.orchardUA.stringEncoded])

        // A fresh explicit Redeem tap is required after the recheck finds funds.
        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive({ if case .response(_, .redeemSucceeded) = $0 { true } else { false } }) {
            $0.step = .success
            $0.txId = GiftCardClient.MockScenario.ready.txId
        }
        await store.receive(\.delegate.redeemed)
        #expect(redeemedTo.value.count == 2)
    }

    /// A card whose wallet is gone (its handle is unknown to the client) is opened again on Retry
    /// instead of being checked through the dead handle forever.
    @Test func unknownHandleOnCheckMakesRetryOpenTheCardAgain() async {
        let openCalls = LockIsolated(0)
        var base = scenario(.ready)
        base.checkError = .unknownHandle
        let store = makeStore(scenario: base, openCalls: openCalls)

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .opened) = $0 { true } else { false } })
        await store.receive({ if case .response(_, .checkFailed) = $0 { true } else { false } }) {
            $0.step = .checkFailed
            $0.handle = nil
        }

        await store.send(.retryTapped) {
            $0.step = .checking
        }
        await store.receive({ if case .response(_, .opened) = $0 { true } else { false } })
        #expect(openCalls.value == 2)
    }

    @Test func redeemIsUnavailableWithoutAnAccount() async {
        let store = makeStore(scenario: scenario(.ready), withAccount: false)

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
        }
        #expect(!store.state.isRedeemable)

        await store.send(.redeemTapped)
        #expect(store.state.step == .ready(spendable: Zatoshi(10_000_000)))
    }

    @Test func changingAccountBeforeRedeemDoesNotUseThePreviousCachedAddress() async {
        let redeemedTo = LockIsolated<[String]>([])
        let store = makeStore(scenario: scenario(.ready), redeemedTo: redeemedTo)
        await store.send(.onAppear)
        await store.receive({ if case .response(_, .destinationResolved) = $0 { true } else { false } })
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } })
        let second = WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: 2, count: 16)), name: "Second", keySource: nil,
            seedFingerprint: nil, hdAccountIndex: Zip32AccountIndex(1), ufvk: nil, uivk: nil
        ))
        store.state.$selectedWalletAccount.withLock { $0 = second }
        store.dependencies.sdkSynchronizer = .mocked(getCustomUnifiedAddress: { id, _ in
            #expect(id == second.id)
            return UnifiedAddress(validatedEncoding: "utest1secondaccount", networkType: .testnet)
        })
        await store.send(.redeemTapped)
        await store.receive({ if case .response(_, .redeemSucceeded) = $0 { true } else { false } })
        await store.finish()
        #expect(redeemedTo.value == ["utest1secondaccount"])
    }

    @Test func accountChangeWhileDestinationIsSuspendedDoesNotCacheOrSendTheOldAddress() async {
        let entered = GiftCardTestGate()
        let release = GiftCardTestGate()
        let redeemedTo = LockIsolated<[String]>([])
        let store = makeStore(scenario: scenario(.ready), redeemedTo: redeemedTo)
        store.dependencies.sdkSynchronizer = .mocked(getCustomUnifiedAddress: { _, _ in
            await entered.open()
            await release.wait()
            return Self.orchardUA
        })
        await store.send(.onAppear)
        await entered.wait()
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } })
        store.state.$selectedWalletAccount.withLock { $0 = nil }
        await release.open()
        await store.receive({ if case .response(_, .destinationResolved) = $0 { true } else { false } })
        await store.finish()
        #expect(store.state.destinationAddress == nil)
        #expect(redeemedTo.value.isEmpty)
    }

    @Test func accountChangeDuringRedeemTimeAddressLookupUsesTheCurrentAccount() async {
        let entered = GiftCardTestGate()
        let release = GiftCardTestGate()
        let redeemedTo = LockIsolated<[String]>([])
        let first = testWalletAccount
        let second = WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: 3, count: 16)), name: "Current", keySource: nil,
            seedFingerprint: nil, hdAccountIndex: Zip32AccountIndex(1), ufvk: nil, uivk: nil
        ))
        var state = GiftCardRedeem.State(link: Self.link)
        state.handle = GiftCardHandle()
        state.step = .ready(spendable: Zatoshi(10_000_000))
        state.$selectedWalletAccount.withLock { $0 = first }
        let store = TestStore(initialState: state) { GiftCardRedeem() } withDependencies: {
            var client = GiftCardClient.mock()
            client.redeem = { _, address in
                redeemedTo.withValue { $0.append(address) }
                return "current-tx"
            }
            $0.giftCard = client
            $0.sdkSynchronizer = .mocked(getCustomUnifiedAddress: { id, _ in
                if id == first.id {
                    await entered.open()
                    await release.wait()
                    return Self.orchardUA
                }
                #expect(id == second.id)
                return UnifiedAddress(validatedEncoding: "utest1currentaccount", networkType: .testnet)
            })
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.redeemTapped)
        await entered.wait()
        store.state.$selectedWalletAccount.withLock { $0 = second }
        await release.open()
        await store.receive({ if case .response(_, .redeemSucceeded) = $0 { true } else { false } })
        await store.finish()
        #expect(redeemedTo.value == ["utest1currentaccount"])
        #expect(store.state.destinationAccountId == second.id)
    }

    @Test func closeAsksToDismiss() async {
        let store = makeStore(scenario: scenario(.ready))

        await store.send(.closeTapped)
        await store.receive(\.delegate.dismiss)
    }

    // MARK: - Live wiring: a failed submission replaces the card's session under its handle

    @Test func liveRedeemReplacesTheCardSessionAfterAFailedSubmission() async throws {
        let registry = GiftCardSessionRegistry()
        let closed = LockIsolated(0)
        let reopened = LockIsolated(0)
        let session = FakeGiftCardSession(
            held: .ready(spendable: Zatoshi(10_000_000)),
            submissionFails: true,
            closed: closed,
            reopened: reopened
        )
        let handle = await registry.insert(session)
        let client = GiftCardClient.live(registry: registry)

        await #expect(throws: GiftCardClientError.redeemFailed) {
            try await withDependencies {
                $0.transactionGuard = .testValue
            } operation: {
                _ = try await client.redeem(handle, Self.orchardUA.stringEncoded)
            }
        }
        // The spent session was closed and a fresh one took its place under the same handle.
        #expect(closed.value == 1)
        #expect(reopened.value == 1)

        let status = try await client.check(handle)
        #expect(status == .ready(spendable: Zatoshi(10_000_000)))

        let txId = try await withDependencies {
            $0.transactionGuard = .testValue
        } operation: {
            try await client.redeem(handle, Self.orchardUA.stringEncoded)
        }
        #expect(txId == FakeGiftCardSession.txId)
        #expect(reopened.value == 1)

        await client.cleanup(handle)
        #expect(closed.value == 2)
        let remaining = await registry.session(for: handle)
        #expect(remaining == nil)
    }

    @Test func liveRedeemFailureWithoutASubmissionKeepsTheSession() async throws {
        let registry = GiftCardSessionRegistry()
        let closed = LockIsolated(0)
        let reopened = LockIsolated(0)
        let session = FakeGiftCardSession(
            held: .ready(spendable: Zatoshi(10_000_000)),
            sendAllError: .networkMismatch,
            closed: closed,
            reopened: reopened
        )
        let handle = await registry.insert(session)
        let client = GiftCardClient.live(registry: registry)

        await #expect(throws: GiftCardClientError.networkMismatch) {
            try await withDependencies {
                $0.transactionGuard = .testValue
            } operation: {
                _ = try await client.redeem(handle, Self.orchardUA.stringEncoded)
            }
        }
        #expect(closed.value == 0)
        #expect(reopened.value == 0)
    }

    @Test func liveRedeemOfANothingToRedeemCardKeepsTheSession() async throws {
        let registry = GiftCardSessionRegistry()
        let closed = LockIsolated(0)
        let reopened = LockIsolated(0)
        let session = FakeGiftCardSession(
            held: .ready(spendable: Zatoshi(5_000)),
            sendAllError: .nothingToRedeem,
            closed: closed,
            reopened: reopened
        )
        let handle = await registry.insert(session)
        let client = GiftCardClient.live(registry: registry)

        await #expect(throws: GiftCardClientError.nothingToRedeem) {
            try await withDependencies {
                $0.transactionGuard = .testValue
                $0.sdkSynchronizer = .mocked()
            } operation: {
                _ = try await client.redeem(handle, Self.orchardUA.stringEncoded)
            }
        }
        // Nothing was created, so the card's wallet is not replaced.
        #expect(closed.value == 0)
        #expect(reopened.value == 0)
    }

    @Test func registryClosesAReplacementForAHandleThatIsGone() async {
        let registry = GiftCardSessionRegistry()
        let closed = LockIsolated(0)
        let replacement = FakeGiftCardSession(held: .empty, closed: closed, reopened: LockIsolated(0))

        let replaced = await registry.replace(GiftCardHandle(), with: replacement)

        #expect(!replaced)
        #expect(closed.value == 1)
    }

    // MARK: - Live wiring: the claim is recorded in the main wallet as trusted (ZIP 315)

    /// A real synchronizer that is never prepared or started: the tests only check that the sweep
    /// is handed this instance. The app tests cannot conform to `Synchronizer` themselves.
    private static func makeMainWallet() -> any Synchronizer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GiftCardRedeemTests-\(UUID().uuidString)", isDirectory: true)
        let initializer = Initializer(
            cacheDbURL: nil,
            fsBlockDbRoot: directory.appendingPathComponent("fs_cache", isDirectory: true),
            generalStorageURL: directory,
            dataDbURL: directory.appendingPathComponent("data.db"),
            torDirURL: directory.appendingPathComponent("tor", isDirectory: true),
            endpoint: LightWalletEndpoint(address: "localhost", port: 9067, secure: false),
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: directory.appendingPathComponent("sapling-spend.params"),
            outputParamsURL: directory.appendingPathComponent("sapling-output.params"),
            saplingParamsSourceURL: .default,
            alias: .custom("giftcardtests"),
            loggingPolicy: .noLogging,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
        return SDKSynchronizer(initializer: initializer)
    }

    /// The redeem screen over the live client and a registry holding `session`: parsing comes from
    /// the mock, opening hands out the registered card, and checking and redeeming go through the
    /// live wiring, with `mainWallet` as the wallet's own synchronizer.
    private func liveWiringStore(
        session: FakeGiftCardSession,
        mainWallet: (any Synchronizer)?
    ) async -> TestStore<GiftCardRedeem.State, GiftCardRedeem.Action> {
        let registry = GiftCardSessionRegistry()
        let handle = await registry.insert(session)
        let live = GiftCardClient.live(registry: registry)
        var client = GiftCardClient.mock(scenario(.ready))
        client.open = { _ in handle }
        client.check = live.check
        client.redeem = live.redeem
        client.cleanup = live.cleanup

        let state = GiftCardRedeem.State(link: Self.link)
        let account = testWalletAccount
        state.$selectedWalletAccount.withLock { $0 = account }

        nonisolated(unsafe) let mainWallet = mainWallet
        let sdkSynchronizer = SDKSynchronizerClient.mocked(
            getCustomUnifiedAddress: { _, _ in Self.orchardUA },
            mainWalletSynchronizer: { mainWallet }
        )

        let store = TestStore(initialState: state) {
            GiftCardRedeem()
        } withDependencies: {
            $0.giftCard = client
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment = .testnet
            $0.transactionGuard = .testValue
            $0.sdkSynchronizer = sdkSynchronizer
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    private func redeemThroughTheLiveWiring(_ store: TestStore<GiftCardRedeem.State, GiftCardRedeem.Action>) async {
        await store.send(.onAppear)
        await store.receive({ if case .response(_, .opened) = $0 { true } else { false } })
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
        }
        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive({ if case .response(_, .redeemSucceeded) = $0 { true } else { false } }) {
            $0.step = .success
            $0.txId = FakeGiftCardSession.txId
        }
        await store.receive(\.delegate.redeemed)
    }

    @Test func redeemRecordsTheClaimInTheMainWallet() async {
        let mainWallet = Self.makeMainWallet()
        let recordedIn = LockIsolated<[ObjectIdentifier?]>([])
        let session = FakeGiftCardSession(
            held: .ready(spendable: Zatoshi(10_000_000)),
            closed: LockIsolated(0),
            reopened: LockIsolated(0),
            recordedIn: recordedIn
        )
        let store = await liveWiringStore(session: session, mainWallet: mainWallet)

        await redeemThroughTheLiveWiring(store)

        // The sweep was handed the wallet's own synchronizer, exactly once.
        #expect(recordedIn.value == [ObjectIdentifier(mainWallet)])
    }

    @Test func claimThatCouldNotBeRecordedStillSucceeds() async {
        let mainWallet = Self.makeMainWallet()
        let recordedIn = LockIsolated<[ObjectIdentifier?]>([])
        let session = FakeGiftCardSession(
            held: .ready(spendable: Zatoshi(10_000_000)),
            closed: LockIsolated(0),
            reopened: LockIsolated(0),
            recordsClaim: false,
            recordedIn: recordedIn
        )
        let store = await liveWiringStore(session: session, mainWallet: mainWallet)

        // Same states as a recorded claim: the funds are on their way either way, and the wallet
        // finds an unrecorded claim on chain.
        await redeemThroughTheLiveWiring(store)

        #expect(recordedIn.value == [ObjectIdentifier(mainWallet)])
        #expect(store.state.step == .success)
    }

    @Test func liveRedeemWithoutAMainWalletStillSucceeds() async throws {
        let registry = GiftCardSessionRegistry()
        let recordedIn = LockIsolated<[ObjectIdentifier?]>([])
        let session = FakeGiftCardSession(
            held: .ready(spendable: Zatoshi(10_000_000)),
            closed: LockIsolated(0),
            reopened: LockIsolated(0),
            recordedIn: recordedIn
        )
        let handle = await registry.insert(session)
        let client = GiftCardClient.live(registry: registry)

        let txId = try await withDependencies {
            $0.transactionGuard = .testValue
            $0.sdkSynchronizer = .mocked()
        } operation: {
            try await client.redeem(handle, Self.orchardUA.stringEncoded)
        }

        #expect(txId == FakeGiftCardSession.txId)
        #expect(recordedIn.value == [nil])
    }
}

/// A `GiftCardSession` stand-in: `sendAll` reports a rejected broadcast (or a given client error),
/// and `reopen` hands out a session for the same card whose sweep succeeds. A successful sweep
/// notes which synchronizer it was asked to record the claim in, and reports it recorded unless
/// `recordsClaim` is off.
private struct FakeGiftCardSession: GiftCardSession {
    static let txId = "fade00fade00fade00fade00fade00fade00fade00fade00fade00fade00fade"

    let held: zodl_internal.GiftCardStatus
    var submissionFails = false
    var sendAllError: GiftCardClientError?
    let closed: LockIsolated<Int>
    let reopened: LockIsolated<Int>
    var recordsClaim = true
    var recordedIn = LockIsolated<[ObjectIdentifier?]>([])

    func progress() -> AsyncStream<Double> {
        AsyncStream { $0.finish() }
    }

    func status() async throws -> zodl_internal.GiftCardStatus {
        held
    }

    func sendAll(to address: String, recordIn mainWallet: GiftCardClaimDestination?) async throws -> GiftCardSweep {
        if let sendAllError {
            throw sendAllError
        }
        if submissionFails {
            throw GiftCardSubmissionFailed()
        }
        recordedIn.withValue { $0.append(mainWallet.map { ObjectIdentifier($0.synchronizer) }) }
        return GiftCardSweep(txId: Self.txId, recordedInMainWallet: recordsClaim && mainWallet != nil)
    }

    func reopen() async throws -> any GiftCardSession {
        await close()
        reopened.withValue { $0 += 1 }
        return FakeGiftCardSession(
            held: held,
            closed: closed,
            reopened: reopened,
            recordsClaim: recordsClaim,
            recordedIn: recordedIn
        )
    }

    func close() async {
        closed.withValue { $0 += 1 }
    }
}

@Suite struct GiftCardRedeemMemoTests {
    @Test func cardWithoutMessageGetsTheLabelOnly() throws {
        let memo = try #require(GiftCardRedeemerSession.redeemMemo(message: nil))
        #expect(memo == (try Memo(string: "Gift card")))
    }

    @Test func cardMessageFollowsTheLabel() throws {
        let memo = try #require(GiftCardRedeemerSession.redeemMemo(message: "  Welcome to Zcash Summit \n"))
        #expect(memo == (try Memo(string: "Gift card · Welcome to Zcash Summit")))
    }

    /// A card whose message hides a right-to-left override, a newline and a bell: the memo is
    /// built from the SDK's sanitized `GiftCard.message`, so none of them reach the wallet history.
    @Test func memoCarriesTheSanitizedMessage() throws {
        let link = [
            "\(GiftCardLink.vizorPrefix)#v3=",
            "WyJtYWluIiwiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsMzQ4MzE0MSwiMTAwMDAwMCIsImtuaWdodE1hZ2ljIiwx",
            "MS4xNzQ3LCJIYXBweeKAriBiaXJ0aGRheVxuZnJvbVx1MDAwNyB1cyJd"
        ].joined()
        let card = try GiftCard(link: link)
        let memo = try #require(GiftCardRedeemerSession.redeemMemo(for: card))
        guard case .text(let text) = memo else {
            Issue.record("expected a text memo")
            return
        }
        let string = text.string
        #expect(string.hasPrefix("Gift card · Happy"))
        #expect(string.contains("birthday"))
        #expect(!string.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format })
    }

    @Test func longMessageIsTrimmedToFitAMemo() throws {
        let message = String(repeating: "é", count: 400)   // 800 bytes
        let memo = try #require(GiftCardRedeemerSession.redeemMemo(message: message))
        guard case .text(let text) = memo else {
            Issue.record("expected a text memo")
            return
        }
        let string = text.string
        #expect(string.hasPrefix("Gift card · é"))
        #expect(string.utf8.count <= MemoBytes.capacity)
        #expect(!string.hasSuffix("\u{FFFD}"))
    }
}

/// How the card's wallet is set up and what the live wiring reports about it.
@Suite struct GiftCardRedeemerSettingsTests {
    private func settings(torFlag: Bool?) -> GiftCardRedeemerSettings {
        withDependencies {
            $0.zcashSDKEnvironment = .testnet
            $0.userDefaults = .noOp
            $0.walletStorage.exportTorSetupFlag = { torFlag }
        } operation: {
            GiftCardRedeemerSettings.current()
        }
    }

    @Test func cardWalletFollowsTheWalletsTorSetting() {
        #expect(settings(torFlag: true).isTorEnabled)
        #expect(!settings(torFlag: false).isTorEnabled)
        #expect(!settings(torFlag: nil).isTorEnabled)
        #expect(settings(torFlag: true).network.networkType == .testnet)
    }

    @Test func cardWalletDoesNotLog() {
        guard case .noLogging = GiftCardRedeemerSettings.loggingPolicy else {
            Issue.record("the card wallet must not log")
            return
        }
    }

    @Test func dustCardHasNothingToRedeem() {
        let pool = PoolBalance(spendableValue: Zatoshi(5_000), changePendingConfirmation: .zero, valuePendingSpendability: .zero)
        let balance = AccountBalance(saplingBalance: .zero, orchardBalance: pool, unshielded: .zero)
        let dust = ZcashLightClientKit.GiftCardStatus(balance: balance, spendableCoversFee: false)

        #expect(dust.state == .dust)
        #expect(GiftCardRedeemerSession.appStatus(dust) == .empty)
        #expect(
            GiftCardRedeemerSession.appStatus(ZcashLightClientKit.GiftCardStatus(balance: balance, spendableCoversFee: true))
                == .ready(spendable: Zatoshi(5_000))
        )
    }

    @Test func rejectedSubmissionIsLoggedWithoutTheServersText() throws {
        let rejected = try #require(
            GiftCardRedeemer.failureDescription(
                of: .submitFailure(txId: Data(repeating: 1, count: 32), code: 18, description: "bad-txns tx 0101 to utest1secret")
            )
        )
        #expect(rejected == "submission rejected (18)")
        #expect(GiftCardRedeemer.failureDescription(of: .success(txId: Data(repeating: 1, count: 32))) == nil)
    }
}
