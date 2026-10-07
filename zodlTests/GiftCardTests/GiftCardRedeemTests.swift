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

// Serialized: mutates the process-global selected-account `@Shared` slot.
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
            $0.step = .ready(redeemable: Zatoshi(10_000_000))
        }
        #expect(store.state.summary?.message == "Welcome to Zcash Summit")
        #expect(store.state.isRedeemable)

        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive({ if case .response(_, .redeemSucceeded) = $0 { true } else { false } }) {
            $0.step = .success(received: Zatoshi(10_000_000))
            $0.txId = GiftCardClient.MockScenario.ready.txId
        }
        await store.receive(\.delegate.redeemed)

        #expect(receivers.value.allSatisfy { $0 == [.orchard] })
        #expect(!receivers.value.isEmpty)
        #expect(redeemedTo.value == [Self.orchardUA.stringEncoded])
    }

    @Test func successfulRedeemKeepsTheTransactionIdAndReportsTheReceivedAmount() async {
        var card = scenario(.ready)
        card.txId = "redeemed-tx"
        let store = makeStore(scenario: card)

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } })
        #expect(store.state.step == .ready(redeemable: Zatoshi(10_000_000)))
        #expect(store.state.amount == Zatoshi(10_000_000))
        #expect(store.state.receivedAmount == Zatoshi(10_000_000))

        await store.send(.redeemTapped)
        #expect(store.state.step == .redeeming(amount: Zatoshi(10_000_000)))
        #expect(store.state.amount == Zatoshi(10_000_000))
        await store.receive({ if case .response(_, .redeemSucceeded) = $0 { true } else { false } })
        await store.receive(\.delegate.redeemed)
        await store.finish()

        // The success screen shows the same received figure as the Ready screen, never the
        // card's pre-fee balance.
        #expect(store.state.step == .success(received: Zatoshi(10_000_000)))
        #expect(store.state.txId == "redeemed-tx")
        #expect(store.state.amount == nil)
        #expect(store.state.receivedAmount == Zatoshi(10_000_000))
    }

    /// The Ready screen shows what the wallet SDK proposed the redemption sends, after the fee the
    /// card's notes require: a card holding several notes pays more than the minimum fee.
    @Test func readyShowsTheRedeemableAmountTheSDKComputed() async {
        var card = scenario(.ready)
        card.status = .ready(spendable: Zatoshi(10_010_000), redeemable: Zatoshi(9_995_000))
        let store = makeStore(scenario: card)

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .ready(redeemable: Zatoshi(9_995_000))
        }
        #expect(store.state.receivedAmount == Zatoshi(9_995_000))
    }

    /// Success shows what the redemption's own proposal sent, which can differ from the Ready
    /// figure (more funds became spendable meanwhile). An amount the redemption did not report is
    /// left unknown rather than replaced with the Ready figure.
    @Test(arguments: [(Optional(Zatoshi(10_500_000)), Optional(Zatoshi(10_500_000))), (nil, nil)])
    func successShowsWhatTheRedemptionSent(reported: Zatoshi?, shown: Zatoshi?) async {
        var state = GiftCardRedeem.State(link: Self.link)
        state.handle = GiftCardHandle()
        state.step = .redeeming(amount: Zatoshi(10_000_000))
        let store = TestStore(initialState: state) { GiftCardRedeem() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.response(state.cancelId, .redeemSucceeded(GiftCardRedemption(txId: "tx", received: reported)))) {
            $0.step = .success(received: shown)
            $0.txId = "tx"
        }
        await store.receive(\.delegate.redeemed)
        #expect(store.state.receivedAmount == shown)
    }

    /// Success names the amount received when it is known, and says the gift is on its way
    /// without an amount otherwise (Android's `redeemGift_success_subtitle_noAmount`).
    @Test func successCopyFollowsWhetherTheAmountIsKnown() {
        let known = GiftCardRedeemView(store: GiftCardRedeem.preview(.success(received: Zatoshi(10_000_000))), tokenName: "ZEC")
        let amount = "\(Zatoshi(10_000_000).atLeastThreeDecimalsZashiFormatted()) ZEC"
        #expect(known.successDesc() == String(localizable: .giftCardSuccessDesc(amount)))

        let unknown = GiftCardRedeemView(store: GiftCardRedeem.preview(.success(received: nil)), tokenName: "ZEC")
        #expect(unknown.successDesc() == String(localizable: .giftCardSuccessDescNoAmount))
    }

    @Test func receivedAmountFollowsEveryStepThatHasAnAmount() {
        var state = GiftCardRedeem.State(link: Self.link)
        let cases: [(GiftCardRedeem.State.Step, Zatoshi?)] = [
            (.checking, nil),
            (.ready(redeemable: Zatoshi(10_000_000)), Zatoshi(10_000_000)),
            (.pending(amount: Zatoshi(10_010_000), confirmationsNeeded: nil), Zatoshi(10_010_000)),
            (.redeeming(amount: Zatoshi(10_000_000)), Zatoshi(10_000_000)),
            (.failure(amount: Zatoshi(10_000_000)), Zatoshi(10_000_000)),
            (.success(received: Zatoshi(10_000_000)), Zatoshi(10_000_000)),
            (.empty, nil),
            (.dust, nil),
            (.invalidLink, nil),
            (.checkFailed, nil)
        ]
        for (step, expected) in cases {
            state.step = step
            #expect(state.receivedAmount == expected, "\(step)")
        }
    }

    /// Errors are laid out as on Android: Try again (with Close) and the skull only where checking
    /// again can help, Close only and the cloud where it cannot.
    @Test func errorStepsOfferTryAgainOnlyWhenItCanHelp() {
        var state = GiftCardRedeem.State(link: Self.link)
        let cases: [(GiftCardRedeem.State.Step, GiftCardRedeem.State.ErrorKind?)] = [
            (.checkFailed, .retryable),
            (.failure(amount: Zatoshi(10_000_000)), .retryable),
            (.invalidLink, .final),
            (.unsupportedVersion, .final),
            (.wrongNetwork, .final),
            (.unavailable, .final),
            (.checking, nil),
            (.ready(redeemable: Zatoshi(10_000_000)), nil),
            (.pending(amount: Zatoshi(10_000_000), confirmationsNeeded: nil), nil),
            (.empty, nil),
            (.dust, nil),
            (.redeeming(amount: Zatoshi(10_000_000)), nil),
            (.success(received: Zatoshi(10_000_000)), nil)
        ]
        for (step, kind) in cases {
            state.step = step
            #expect(state.errorKind == kind, "\(step)")
            if let kind {
                #expect(state.canRetry == (kind == .retryable), "\(step)")
            }
        }
    }

    /// Try again is ignored on an error it cannot help.
    @Test(arguments: [
        GiftCardRedeem.State.Step.invalidLink, .unsupportedVersion, .wrongNetwork, .unavailable
    ])
    func retryOnAFinalErrorDoesNothing(step: GiftCardRedeem.State.Step) async {
        let openCalls = LockIsolated(0)
        var state = GiftCardRedeem.State(link: Self.link)
        state.step = step
        let store = TestStore(initialState: state) {
            GiftCardRedeem()
        } withDependencies: {
            var client = GiftCardClient.mock(scenario(.ready))
            client.open = { _ in
                openCalls.withValue { $0 += 1 }
                return GiftCardHandle()
            }
            $0.giftCard = client
        }

        await store.send(.retryTapped)
        await store.finish()
        #expect(openCalls.value == 0)
    }

    /// The pending screen checks again on its own, without leaving the screen, and keeps doing so
    /// while the card stays pending.
    @Test func pendingCardChecksAgainOnItsOwnWithoutLeavingTheScreen() async {
        let mainQueue = DispatchQueue.test
        let checks = LockIsolated(0)
        let store = makeStore(scenario: scenario(.pending), mainQueue: mainQueue.eraseToAnyScheduler())
        let pending = store.dependencies.giftCard.check
        store.dependencies.giftCard.check = { handle in
            checks.withValue { $0 += 1 }
            return try await pending(handle)
        }

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 3)
        }
        #expect(!store.state.isRedeemable)

        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval))
        await store.receive({ if case .response(_, .autoRetryFired) = $0 { true } else { false } }) {
            $0.isQuietCheckInFlight = true
        }
        #expect(store.state.step == .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 3))
        #expect(!store.state.isRechecking)
        await store.receive({ if case .response(_, .recheckLoaded) = $0 { true } else { false } }) {
            $0.isQuietCheckInFlight = false
        }

        // Still pending: the next check is scheduled.
        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval))
        await store.receive({ if case .response(_, .autoRetryFired) = $0 { true } else { false } })
        await store.receive({ if case .response(_, .recheckLoaded) = $0 { true } else { false } })
        #expect(checks.value == 3)

        await store.send(.closeTapped)
        await store.receive(\.delegate.dismiss)
        await store.finish()
    }

    /// The pending screen's periodic check pauses while the app is in the background and picks up
    /// again, a full interval later, once it is back.
    @Test func pendingRecheckPausesWhileTheAppIsInTheBackground() async {
        let mainQueue = DispatchQueue.test
        let checks = LockIsolated(0)
        let store = makeStore(scenario: scenario(.pending), mainQueue: mainQueue.eraseToAnyScheduler())
        let pending = store.dependencies.giftCard.check
        store.dependencies.giftCard.check = { handle in
            checks.withValue { $0 += 1 }
            return try await pending(handle)
        }

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } })
        #expect(checks.value == 1)

        await store.send(.appDidEnterBackground) {
            $0.isInBackground = true
        }
        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval * 3))
        #expect(checks.value == 1)

        await store.send(.appWillEnterForeground) {
            $0.isInBackground = false
        }
        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval - 1))
        #expect(checks.value == 1)
        await mainQueue.advance(by: .seconds(1))
        await store.receive({ if case .response(_, .autoRetryFired) = $0 { true } else { false } })
        await store.receive({ if case .response(_, .recheckLoaded) = $0 { true } else { false } })
        #expect(checks.value == 2)

        await store.send(.closeTapped)
        await store.finish()
    }

    /// A check that answers pending while the app is in the background does not schedule the next
    /// one; coming back does.
    @Test func pendingAnswerInTheBackgroundWaitsForTheForeground() async {
        let mainQueue = DispatchQueue.test
        let checks = LockIsolated(0)
        let store = makeStore(scenario: scenario(.pending), mainQueue: mainQueue.eraseToAnyScheduler())
        let pending = store.dependencies.giftCard.check
        store.dependencies.giftCard.check = { handle in
            checks.withValue { $0 += 1 }
            return try await pending(handle)
        }

        await store.send(.appDidEnterBackground) {
            $0.isInBackground = true
        }
        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 3)
        }
        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval * 2))
        #expect(checks.value == 1)

        await store.send(.appWillEnterForeground)
        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval))
        await store.receive({ if case .response(_, .autoRetryFired) = $0 { true } else { false } })
        await store.receive({ if case .response(_, .recheckLoaded) = $0 { true } else { false } })
        #expect(checks.value == 2)

        await store.send(.closeTapped)
        await store.finish()
    }

    /// Coming back to a screen that isn't pending schedules nothing.
    @Test func foregroundOnAScreenThatIsNotPendingSchedulesNothing() async {
        let mainQueue = DispatchQueue.test
        let checks = LockIsolated(0)
        let store = makeStore(scenario: scenario(.ready), mainQueue: mainQueue.eraseToAnyScheduler())
        let ready = store.dependencies.giftCard.check
        store.dependencies.giftCard.check = { handle in
            checks.withValue { $0 += 1 }
            return try await ready(handle)
        }

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } })
        await store.send(.appDidEnterBackground)
        await store.send(.appWillEnterForeground)
        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval * 2))
        #expect(checks.value == 1)
        await store.finish()
    }

    /// Funds that become spendable while the pending screen waits take it to Ready on their own.
    @Test func pendingCardTurnsReadyOnItsOwn() async {
        let mainQueue = DispatchQueue.test
        let checks = LockIsolated(0)
        let store = makeStore(scenario: scenario(.pending), mainQueue: mainQueue.eraseToAnyScheduler())
        store.dependencies.giftCard.check = { _ in
            checks.withValue { count in
                count += 1
                return count == 1
                    ? .pending(amount: Zatoshi(10_010_000), confirmationsNeeded: nil)
                    : .ready(spendable: Zatoshi(10_010_000), redeemable: Zatoshi(10_000_000))
            }
        }

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } })
        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval))
        await store.receive({ if case .response(_, .autoRetryFired) = $0 { true } else { false } })
        await store.receive({ if case .response(_, .recheckLoaded) = $0 { true } else { false } }) {
            $0.step = .ready(redeemable: Zatoshi(10_000_000))
        }
        // Ready stops the periodic check.
        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval * 2))
        #expect(checks.value == 2)
        await store.finish()
    }

    /// Check again on the pending screen keeps the screen, shows the button busy, and a failed
    /// check leaves the screen as it was.
    @Test func checkAgainOnPendingKeepsTheScreenEvenWhenTheCheckFails() async {
        let mainQueue = DispatchQueue.test
        let checks = LockIsolated(0)
        let release = GiftCardTestGate()
        let store = makeStore(scenario: scenario(.pending), mainQueue: mainQueue.eraseToAnyScheduler())
        store.dependencies.giftCard.check = { _ in
            let count = checks.withValue { count in
                count += 1
                return count
            }
            if count == 1 {
                return .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: nil)
            }
            // Held until the test lets it fail, so a second tap lands while it runs.
            await release.wait()
            throw GiftCardClientError.checkFailed
        }

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } })

        await store.send(.retryTapped) {
            $0.isRechecking = true
            $0.isQuietCheckInFlight = true
        }
        #expect(store.state.step == .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: nil))
        // A second tap while it runs does not start another check.
        await store.send(.retryTapped)
        await release.open()
        await mainQueue.advance(by: .milliseconds(GiftCardRedeem.Constants.recheckMinimumBusyTime))
        await store.receive({ if case .response(_, .recheckFailed) = $0 { true } else { false } }) {
            $0.isRechecking = false
            $0.isQuietCheckInFlight = false
        }
        #expect(store.state.step == .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: nil))
        #expect(checks.value == 2)

        // The pending screen goes on checking on its own.
        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval))
        await store.receive({ if case .response(_, .autoRetryFired) = $0 { true } else { false } })
        await store.receive({ if case .response(_, .recheckFailed) = $0 { true } else { false } })
        #expect(checks.value == 3)
        await store.send(.closeTapped)
        await store.finish()
    }

    /// A Check again the user taps keeps its button busy for a moment even when the card answers at
    /// once, so the tap visibly does something (Android's QUIET_RECHECK_MIN_DURATION).
    @Test func checkAgainStaysBusyForAMinimumTime() async {
        let mainQueue = DispatchQueue.test
        let checks = LockIsolated(0)
        let store = makeStore(scenario: scenario(.pending), mainQueue: mainQueue.eraseToAnyScheduler())
        store.dependencies.giftCard.check = { _ in
            checks.withValue { $0 += 1 }
            return .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: nil)
        }

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } })

        await store.send(.retryTapped) {
            $0.isRechecking = true
            $0.isQuietCheckInFlight = true
        }
        await mainQueue.advance(by: .milliseconds(GiftCardRedeem.Constants.recheckMinimumBusyTime - 1))
        await Task.megaYield()
        // The card has answered, but the button is still busy.
        #expect(checks.value == 2)
        #expect(store.state.isRechecking)

        await mainQueue.advance(by: .milliseconds(1))
        await store.receive({ if case .response(_, .recheckLoaded) = $0 { true } else { false } }) {
            $0.isRechecking = false
            $0.isQuietCheckInFlight = false
        }
        await store.send(.closeTapped)
        await store.finish()
    }

    /// Check again on Nothing to redeem checks the open card quietly: the screen stays until funds
    /// are found.
    @Test func checkAgainOnAnEmptyCardKeepsTheScreenUntilFundsArrive() async {
        let checks = LockIsolated(0)
        let openCalls = LockIsolated(0)
        let store = makeStore(scenario: scenario(.empty), openCalls: openCalls)
        store.dependencies.giftCard.check = { _ in
            checks.withValue { count in
                count += 1
                return count == 1 ? .empty : .ready(spendable: Zatoshi(10_010_000), redeemable: Zatoshi(10_000_000))
            }
        }

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .empty
        }
        await store.send(.retryTapped) {
            $0.isRechecking = true
            $0.isQuietCheckInFlight = true
        }
        #expect(store.state.step == .empty)
        await store.receive({ if case .response(_, .recheckLoaded) = $0 { true } else { false } }) {
            $0.isRechecking = false
            $0.isQuietCheckInFlight = false
            $0.step = .ready(redeemable: Zatoshi(10_000_000))
        }
        #expect(openCalls.value == 1)
    }

    /// A quiet check that finds the card's wallet gone keeps the screen, and the next Check again
    /// opens the card anew.
    @Test func quietCheckOfAGoneCardMakesTheNextCheckAgainOpenItAgain() async {
        let openCalls = LockIsolated(0)
        let checks = LockIsolated(0)
        let store = makeStore(scenario: scenario(.empty), openCalls: openCalls)
        store.dependencies.giftCard.check = { _ in
            let count = checks.withValue { count in
                count += 1
                return count
            }
            if count == 2 {
                throw GiftCardClientError.unknownHandle
            }
            return .empty
        }

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } })
        await store.send(.retryTapped)
        await store.receive({ if case .response(_, .recheckFailed) = $0 { true } else { false } }) {
            $0.isRechecking = false
            $0.isQuietCheckInFlight = false
            $0.handle = nil
        }
        #expect(store.state.step == .empty)

        await store.send(.retryTapped) {
            $0.step = .checking
        }
        await store.receive({ if case .response(_, .opened) = $0 { true } else { false } })
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } })
        #expect(openCalls.value == 2)
    }

    @Test func closeCancelsPendingCardRecheck() async {
        let mainQueue = DispatchQueue.test
        let checkCalls = LockIsolated(0)
        var client = GiftCardClient.mock(scenario(.pending))
        client.check = { _ in
            checkCalls.withValue { $0 += 1 }
            return .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 3)
        }

        var state = GiftCardRedeem.State(link: Self.link)
        state.handle = GiftCardHandle()
        let store = TestStore(initialState: state) {
            GiftCardRedeem()
        } withDependencies: {
            $0.giftCard = client
            $0.mainQueue = mainQueue.eraseToAnyScheduler()
            $0.zcashSDKEnvironment = .testnet
        }

        await store.send(.response(state.cancelId, .statusLoaded(.pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 3)))) {
            $0.step = .pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 3)
        }
        await store.send(.closeTapped)
        await store.receive(\.delegate.dismiss)

        let countAtClose = checkCalls.value
        await mainQueue.advance(by: .seconds(GiftCardRedeem.Constants.autoRetryInterval * 2))
        #expect(checkCalls.value == countAtClose)
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
        base.status = .ready(spendable: .zero, redeemable: .zero)
        let store = makeStore(scenario: base)

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .empty
        }
    }

    /// A card holding no more than the network fee has nothing to redeem, and checking it again
    /// cannot help: only Close is offered.
    @Test(arguments: [
        zodl_internal.GiftCardStatus.dust,
        zodl_internal.GiftCardStatus.ready(spendable: Zatoshi(10_000), redeemable: .zero)
    ])
    func dustCardOffersOnlyClose(status: zodl_internal.GiftCardStatus) async {
        var base = scenario(.dust)
        base.status = status
        let checks = LockIsolated(0)
        let store = makeStore(scenario: base)
        let check = store.dependencies.giftCard.check
        store.dependencies.giftCard.check = { handle in
            checks.withValue { $0 += 1 }
            return try await check(handle)
        }

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .dust
        }
        #expect(!store.state.isRedeemable)
        #expect(!store.state.canRetry)

        await store.send(.retryTapped)
        await store.finish()
        #expect(store.state.step == .dust)
        #expect(checks.value == 1)
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

    /// The card was redeemed elsewhere, or holds too little to pay the fee, by the time it was swept:
    /// nothing was sent, so the card is checked again and the screen says which, instead of
    /// offering a Retry that would fail the same way.
    @Test(arguments: [zodl_internal.GiftCardStatus.empty, zodl_internal.GiftCardStatus.dust])
    func nothingToRedeemOnRedeemChecksTheCardAgain(found: zodl_internal.GiftCardStatus) async {
        let checks = LockIsolated(0)
        let store = makeStore(scenario: scenario(GiftCardClient.MockScenario(redeemError: .nothingToRedeem)))
        store.dependencies.giftCard.check = { _ in
            checks.withValue { count in
                count += 1
                return count == 1 ? .ready(spendable: Zatoshi(10_010_000), redeemable: Zatoshi(10_000_000)) : found
            }
        }

        await store.send(.onAppear)
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = .ready(redeemable: Zatoshi(10_000_000))
        }
        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive({ if case .response(_, .redeemFailed) = $0 { true } else { false } }) {
            $0.step = .checking
        }
        await store.receive({ if case .response(_, .statusLoaded) = $0 { true } else { false } }) {
            $0.step = found == .dust ? .dust : .empty
        }
        #expect(!store.state.isRedeemable)
        #expect(checks.value == 2)
    }

    @Test(arguments: [
        ("en", "Redemption not confirmed", "We couldn't confirm redemption. Tap Try again to check the card's current status."),
        ("es", "Canje no confirmado", "No pudimos confirmar el canje. Toca Intentar de nuevo para comprobar el estado actual de la tarjeta.")
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
                return count == 1 ? .ready(spendable: Zatoshi(10_010_000), redeemable: Zatoshi(10_000_000)) : .empty
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
        #expect(store.state.step == .ready(redeemable: Zatoshi(10_000_000)))
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
            $0.step = .ready(redeemable: Zatoshi(10_000_000))
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
            $0.step = .ready(redeemable: Zatoshi(10_000_000))
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
            $0.step = .ready(redeemable: Zatoshi(10_000_000))
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
            $0.step = .ready(redeemable: Zatoshi(10_000_000))
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
            $0.step = .success(received: Zatoshi(10_000_000))
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
            $0.step = .ready(redeemable: Zatoshi(10_000_000))
        }
        #expect(!store.state.isRedeemable)

        await store.send(.redeemTapped)
        #expect(store.state.step == .ready(redeemable: Zatoshi(10_000_000)))
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
        state.step = .ready(redeemable: Zatoshi(10_000_000))
        state.$selectedWalletAccount.withLock { $0 = first }
        let store = TestStore(initialState: state) { GiftCardRedeem() } withDependencies: {
            var client = GiftCardClient.mock()
            client.redeem = { _, address in
                redeemedTo.withValue { $0.append(address) }
                return GiftCardRedemption(txId: "current-tx", received: nil)
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
            held: .ready(spendable: Zatoshi(10_010_000), redeemable: Zatoshi(10_000_000)),
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
        #expect(status == .ready(spendable: Zatoshi(10_010_000), redeemable: Zatoshi(10_000_000)))

        let redemption = try await withDependencies {
            $0.transactionGuard = .testValue
        } operation: {
            try await client.redeem(handle, Self.orchardUA.stringEncoded)
        }
        #expect(redemption == GiftCardRedemption(txId: FakeGiftCardSession.txId, received: FakeGiftCardSession.received))
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
            held: .ready(spendable: Zatoshi(10_010_000), redeemable: Zatoshi(10_000_000)),
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
            held: .dust,
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
            $0.step = .ready(redeemable: Zatoshi(10_000_000))
        }
        await store.send(.redeemTapped) {
            $0.step = .redeeming(amount: Zatoshi(10_000_000))
        }
        await store.receive({ if case .response(_, .redeemSucceeded) = $0 { true } else { false } }) {
            // What the sweep's proposal sent, not the Ready figure.
            $0.step = .success(received: FakeGiftCardSession.received)
            $0.txId = FakeGiftCardSession.txId
        }
        await store.receive(\.delegate.redeemed)
    }

    @Test func redeemRecordsTheClaimInTheMainWallet() async {
        let mainWallet = Self.makeMainWallet()
        let recordedIn = LockIsolated<[ObjectIdentifier?]>([])
        let session = FakeGiftCardSession(
            held: .ready(spendable: Zatoshi(10_010_000), redeemable: Zatoshi(10_000_000)),
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
            held: .ready(spendable: Zatoshi(10_010_000), redeemable: Zatoshi(10_000_000)),
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
        #expect(store.state.step == .success(received: FakeGiftCardSession.received))
    }

    @Test func liveRedeemWithoutAMainWalletStillSucceeds() async throws {
        let registry = GiftCardSessionRegistry()
        let recordedIn = LockIsolated<[ObjectIdentifier?]>([])
        let session = FakeGiftCardSession(
            held: .ready(spendable: Zatoshi(10_010_000), redeemable: Zatoshi(10_000_000)),
            closed: LockIsolated(0),
            reopened: LockIsolated(0),
            recordedIn: recordedIn
        )
        let handle = await registry.insert(session)
        let client = GiftCardClient.live(registry: registry)

        let redemption = try await withDependencies {
            $0.transactionGuard = .testValue
            $0.sdkSynchronizer = .mocked()
        } operation: {
            try await client.redeem(handle, Self.orchardUA.stringEncoded)
        }

        #expect(redemption.txId == FakeGiftCardSession.txId)
        #expect(recordedIn.value == [nil])
    }
}

/// A `GiftCardSession` stand-in: `sendAll` reports a rejected broadcast (or a given client error),
/// and `reopen` hands out a session for the same card whose sweep succeeds. A successful sweep
/// notes which synchronizer it was asked to record the claim in, and reports it recorded unless
/// `recordsClaim` is off.
private struct FakeGiftCardSession: GiftCardSession {
    static let txId = "fade00fade00fade00fade00fade00fade00fade00fade00fade00fade00fade"
    static let received = Zatoshi(9_995_000)

    let held: zodl_internal.GiftCardStatus
    var submissionFails = false
    var sendAllError: GiftCardClientError?
    let closed: LockIsolated<Int>
    let reopened: LockIsolated<Int>
    var recordsClaim = true
    var recordedIn = LockIsolated<[ObjectIdentifier?]>([])

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
        return GiftCardSweep(txId: Self.txId, recordedInMainWallet: recordsClaim && mainWallet != nil, received: Self.received)
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
        #expect(memo == (try Memo(string: "Gift Card")))
    }

    @Test func cardMessageFollowsTheLabel() throws {
        let memo = try #require(GiftCardRedeemerSession.redeemMemo(message: "  Welcome to Zcash Summit \n"))
        #expect(memo == (try Memo(string: "Gift Card · Welcome to Zcash Summit")))
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
        #expect(string.hasPrefix("Gift Card · Happy"))
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
        #expect(string.hasPrefix("Gift Card · é"))
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
        let dust = ZcashLightClientKit.GiftCardStatus(balance: balance, sweep: nil)

        #expect(dust.state == .dust)
        #expect(GiftCardRedeemerSession.appStatus(dust) == .dust)
    }

    /// A ready card carries the SDK's own figures: the fee its notes require and what the
    /// redemption sends after it, never an app-side estimate.
    @Test func readyCardCarriesTheSDKsRedeemableAmount() {
        let pool = PoolBalance(spendableValue: Zatoshi(10_010_000), changePendingConfirmation: .zero, valuePendingSpendability: .zero)
        let balance = AccountBalance(saplingBalance: .zero, orchardBalance: pool, unshielded: .zero)
        let sweep = ZcashLightClientKit.GiftCardStatus.Sweep(fee: Zatoshi(15_000), amount: Zatoshi(9_995_000))
        let ready = ZcashLightClientKit.GiftCardStatus(balance: balance, sweep: sweep)

        #expect(GiftCardRedeemerSession.appStatus(ready) == .ready(spendable: Zatoshi(10_010_000), redeemable: Zatoshi(9_995_000)))
    }

    /// A pending card shows what is still waiting for confirmations.
    @Test func pendingCardReportsWhatIsWaiting() {
        let pool = PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: Zatoshi(10_010_000))
        let balance = AccountBalance(saplingBalance: .zero, orchardBalance: pool, unshielded: .zero)
        let pending = ZcashLightClientKit.GiftCardStatus(balance: balance, sweep: nil)

        #expect(GiftCardRedeemerSession.appStatus(pending) == .pending(amount: Zatoshi(10_010_000), confirmationsNeeded: nil))
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
