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

        // The timed re-check is quiet: the pending screen stays, and the button does not spin.
        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval))
        await store.receive(\.autoRetryFired)
        #expect(store.state.step == .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 3))
        #expect(!store.state.isRechecking)
        await store.receive(\.statusLoaded) {
            $0.step = .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 3)
        }

        await store.send(.closeTapped)
        await store.receive(\.delegate.dismiss)
        await store.finish()
    }

    /// "Check again" on a pending card re-checks in place: the button shows progress instead of
    /// the screen flickering through the checking step, and the new count replaces the old one.
    @Test func checkAgainOnAPendingCardRechecksInPlace() async {
        let mainQueue = DispatchQueue.test
        let checks = LockIsolated(0)
        var client = GiftCardClient.mock(scenario(.pending))
        client.check = { _ in
            let attempt = checks.withValue { $0 += 1; return $0 }
            return .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: attempt == 1 ? 7 : 6)
        }
        let store = TestStore(initialState: GiftCardRedeem.State(link: Self.link)) {
            GiftCardRedeem()
        } withDependencies: {
            $0.giftCard = client
            $0.mainQueue = mainQueue.eraseToAnyScheduler()
            $0.zcashSDKEnvironment = .testnet
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(getCustomUnifiedAddress: { _, _ in Self.orchardUA })
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(\.statusLoaded) {
            $0.step = .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 7)
        }

        await store.send(.retryTapped) {
            $0.isRechecking = true
        }
        #expect(store.state.step == .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 7))
        await store.receive(\.statusLoaded) {
            $0.isRechecking = false
            $0.step = .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 6)
        }
        #expect(checks.value == 2)

        await store.send(.closeTapped)
        await store.receive(\.delegate.dismiss)
        await store.finish()
    }

    /// A tap while a re-check is already in flight starts nothing.
    @Test func checkAgainWhileRecheckingDoesNothing() async {
        let checks = LockIsolated(0)
        var client = GiftCardClient.mock(scenario(.pending))
        client.check = { _ in
            checks.withValue { $0 += 1 }
            return .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 6)
        }
        var state = GiftCardRedeem.State(link: Self.link)
        state.handle = GiftCardHandle()
        state.step = .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 7)
        state.isRechecking = true
        let store = TestStore(initialState: state) {
            GiftCardRedeem()
        } withDependencies: {
            $0.giftCard = client
        }

        await store.send(.retryTapped)
        await store.finish()
        #expect(checks.value == 0)
    }

    /// A re-check of a pending card that fails keeps the pending screen and tries again later.
    @Test func failedRecheckOfAPendingCardKeepsThePendingScreen() async {
        let mainQueue = DispatchQueue.test
        let checks = LockIsolated(0)
        var client = GiftCardClient.mock(scenario(.pending))
        client.check = { _ in
            let attempt = checks.withValue { $0 += 1; return $0 }
            if attempt == 2 {
                throw GiftCardClientError.checkFailed
            }
            return .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 5)
        }
        let store = TestStore(initialState: GiftCardRedeem.State(link: Self.link)) {
            GiftCardRedeem()
        } withDependencies: {
            $0.giftCard = client
            $0.mainQueue = mainQueue.eraseToAnyScheduler()
            $0.zcashSDKEnvironment = .testnet
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(getCustomUnifiedAddress: { _, _ in Self.orchardUA })
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear)
        await store.receive(\.statusLoaded)
        await store.send(.retryTapped) {
            $0.isRechecking = true
        }
        await store.receive(\.checkFailed) {
            $0.isRechecking = false
        }
        #expect(store.state.step == .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 5))

        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval))
        await store.receive(\.autoRetryFired)
        await store.receive(\.statusLoaded)
        #expect(checks.value == 3)

        await store.send(.closeTapped)
        await store.receive(\.delegate.dismiss)
        await store.finish()
    }

    /// Android's estimate: confirmations × 75 s, rounded up to whole minutes.
    @Test func pendingMinutesRoundUpAtTheTargetBlockTime() {
        #expect(GiftCardRedeem.State.minutes(forConfirmations: 1) == 2)
        #expect(GiftCardRedeem.State.minutes(forConfirmations: 4) == 5)
        #expect(GiftCardRedeem.State.minutes(forConfirmations: 7) == 9)
        #expect(GiftCardRedeem.State.minutes(forConfirmations: 9) == 12)
    }

    /// One confirmation reads in the singular and two in the plural, in English and Spanish.
    @Test func pendingConfirmationsUseThePluralFormForTheCount() throws {
        let english = "before it can be redeemed. We'll keep checking while this screen is open."
        let spanish = "antes de poder canjearse. Seguiremos verificando mientras esta pantalla esté abierta."

        let en1 = try pendingConfirmations(1, language: "en")
        #expect(en1 == "0.1 ZEC needs 1 more confirmation (about 2 min) \(english)")
        let en2 = try pendingConfirmations(2, language: "en")
        #expect(en2 == "0.1 ZEC needs 2 more confirmations (about 3 min) \(english)")
        let es1 = try pendingConfirmations(1, language: "es")
        #expect(es1 == "0.1 ZEC necesita 1 confirmación más (unos 2 min) \(spanish)")
        let es2 = try pendingConfirmations(2, language: "es")
        #expect(es2 == "0.1 ZEC necesita 2 confirmaciones más (unos 3 min) \(spanish)")

        // The screen's own lookup, in the app's current language, agrees with the catalog.
        let language = try #require(Bundle.main.preferredLocalizations.first)
        for confirmations in [1, 2] {
            let expected = try pendingConfirmations(confirmations, language: language)
            let shown = String(
                localizable: .giftCardPendingDescConfirmations(
                    "0.1 ZEC",
                    confirmations: confirmations,
                    GiftCardRedeem.State.minutes(forConfirmations: confirmations)
                )
            )
            #expect(shown == expected)
        }
    }

    /// `giftCard.pending.descConfirmations` from the app's `language` localization, formatted the way
    /// `String(localizable:)` formats it.
    private func pendingConfirmations(_ confirmations: Int, language: String) throws -> String {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let format = bundle.localizedString(forKey: "giftCard.pending.descConfirmations", value: nil, table: "Localizable")
        let arguments: [CVarArg] = ["0.1 ZEC", confirmations, GiftCardRedeem.State.minutes(forConfirmations: confirmations)]
        return String(format: format, locale: nil, arguments: arguments)
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

    /// The card held too little to pay the fee (or was redeemed elsewhere) by the time it was
    /// swept: nothing was sent, so the screen says there is nothing to redeem instead of offering
    /// a Retry that would fail the same way.
    @Test func nothingToRedeemOnRedeemShowsTheEmptyCard() async {
        let store = makeStore(scenario: scenario(GiftCardClient.MockScenario(redeemError: .nothingToRedeem)))

        await store.send(.onAppear)
        await store.receive(\.statusLoaded) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
        }
        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive(\.redeemFailed) {
            $0.step = .empty
        }
        #expect(!store.state.isRedeemable)
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

    /// A broadcast that fails once: Retry re-checks the card through the handle it already has
    /// (the client swaps the card's wallet underneath it), finds the funds still there, and the
    /// next tap sweeps them.
    @Test func retryAfterAFailedRedeemChecksTheSameCardAndThenSucceeds() async {
        let openCalls = LockIsolated(0)
        let redeemedTo = LockIsolated<[String]>([])
        let store = makeStore(scenario: scenario(.redeemFailsOnce), redeemedTo: redeemedTo, openCalls: openCalls)

        await store.send(.onAppear)
        await store.receive(\.opened)
        await store.receive(\.statusLoaded) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
        }
        let handle = store.state.handle

        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive(\.redeemFailed) {
            $0.step = .failure(amount: Zatoshi(10_000_000))
        }
        #expect(store.state.canRetry)

        await store.send(.retryTapped) {
            $0.step = .checking
        }
        await store.receive(\.statusLoaded) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
        }
        #expect(store.state.handle == handle)
        #expect(openCalls.value == 1)

        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive(\.redeemSucceeded) {
            $0.step = .success(amount: Zatoshi(10_000_000))
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
        await store.receive(\.opened)
        await store.receive(\.checkFailed) {
            $0.step = .checkFailed
            $0.handle = nil
        }

        await store.send(.retryTapped) {
            $0.step = .checking
        }
        await store.receive(\.opened)
        #expect(openCalls.value == 2)
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
        await store.receive(\.opened)
        await store.receive(\.statusLoaded) {
            $0.step = .ready(spendable: Zatoshi(10_000_000))
        }
        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive(\.redeemSucceeded) {
            $0.step = .success(amount: Zatoshi(10_000_000))
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
        #expect(store.state.step == .success(amount: Zatoshi(10_000_000)))
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

    /// The SDK's count of confirmations still missing reaches the pending screen.
    @Test func pendingCardCarriesTheConfirmationsRemaining() {
        let pool = PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: Zatoshi(500_000))
        let balance = AccountBalance(saplingBalance: .zero, orchardBalance: pool, unshielded: .zero)

        let known = ZcashLightClientKit.GiftCardStatus(balance: balance, spendableCoversFee: true, confirmationsRemaining: 7)
        #expect(GiftCardRedeemerSession.appStatus(known) == .pending(amount: Zatoshi(500_000), confirmationsNeeded: 7))

        let unknown = ZcashLightClientKit.GiftCardStatus(balance: balance, spendableCoversFee: true)
        #expect(GiftCardRedeemerSession.appStatus(unknown) == .pending(amount: Zatoshi(500_000), confirmationsNeeded: nil))
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
