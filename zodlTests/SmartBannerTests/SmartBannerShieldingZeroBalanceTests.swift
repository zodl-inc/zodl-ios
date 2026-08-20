//
//  SmartBannerShieldingZeroBalanceTests.swift
//  zodlTests
//
//  MOB-1755: shielding a transparent deposit produced a SECOND shielding banner right behind it —
//  offering "Shield 0.000 ZEC" — and tapping it ended on a `ZUNKWN0001` alert, because
//  `proposeShielding` had nothing left to propose.
//
//  The cause was one field wearing three hats. `state.transparentBalance` was the banner's
//  displayed amount, the input to the "should shielding be offered" comparison, AND was written to
//  `.zero` optimistically when a shield succeeded — so a cosmetic update decided control flow. On
//  top of that the offer was retracted only while the banner was already on SCREEN, though
//  `.triggerPriority` claims the slot and opens it `state.delay` seconds later.
//
//  It now mirrors the SDK verbatim and is written nowhere else, the rising edge is read from two
//  SDK-reported figures, and both routes to the banner go through one reminder-aware funnel. This
//  suite pins that behaviour, plus the threshold guards that keep an unshieldable banner
//  unrepresentable whichever path seats it.
//

import Foundation
import Testing
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) @MainActor struct SmartBannerShieldingZeroBalanceTests {
    /// `ZcashSDKEnvironmentTestKey`'s `shieldingThreshold`. Anything under this is what
    /// `proposeShielding` answers with a nil proposal.
    private static let threshold = Zatoshi(100_000)

    private static func account(idByte: UInt8 = 7) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// `.synchronizerStateChanged` only walks its body when the sync STATUS differs from the last
    /// snapshot it stored, so a test driving two consecutive ticks has to vary `syncStatus` for the
    /// second one to be looked at at all.
    private static func syncState(
        account: WalletAccount,
        unshielded: Zatoshi,
        syncStatus: SyncStatus = .upToDate
    ) -> RedactableSynchronizerState {
        var syncState = SynchronizerState.zero
        syncState.syncStatus = syncStatus
        syncState.accountsBalances = [
            account.id: AccountBalance(saplingBalance: .zero, orchardBalance: .zero, unshielded: unshielded)
        ]
        return syncState.redacted
    }

    /// The balance the SDK still reports while a just-submitted shielding transaction has yet to be
    /// recorded as spending it — the figure MOB-1755's banner was raised from.
    private static func staleBalances(account: WalletAccount) -> [AccountUUID: AccountBalance] {
        [account.id: AccountBalance(saplingBalance: .zero, orchardBalance: .zero, unshielded: Zatoshi(1_010_000))]
    }

    /// `.shielding` is pending, `.shielded` is not — `TransactionState.isPending`.
    private static func shieldingTransaction(status: TransactionState.Status) -> TransactionState {
        TransactionState(
            fee: Zatoshi(10_000),
            id: "shield-\(status)",
            status: status,
            zecAmount: Zatoshi(1_010_000),
            isShieldingTransaction: true
        )
    }

    private func makeStore(
        account: WalletAccount,
        transparentBalance: Zatoshi = .zero,
        priorityContent: SmartBanner.State.PriorityContent? = nil,
        priorityContentRequested: SmartBanner.State.PriorityContent? = nil,
        isOpen: Bool = false
    ) -> TestStore<SmartBanner.State, SmartBanner.Action> {
        var state = SmartBanner.State()
        state.$selectedWalletAccount.withLock { $0 = account }
        state.transparentBalance = transparentBalance
        state.priorityContent = priorityContent
        state.priorityContentRequested = priorityContentRequested
        state.isOpen = isOpen

        let store = TestStore(initialState: state) {
            SmartBanner()
        }
        store.exhaustivity = .off
        store.dependencies.mainQueue = .immediate
        store.dependencies.walletStorage = .noOp
        return store
    }

    // MARK: - Defect 1: a seated-but-not-yet-open request must be retracted too

    /// The reported sequence, exactly: the ladder seats `priority7` (banner not on screen yet — it
    /// opens `state.delay` later), the shield the user already started succeeds inside that window,
    /// and the request must die with it rather than open against the freshly zeroed balance.
    @Test func successRetractsAShieldingBannerThatIsSeatedButNotYetOpen() async {
        let account = Self.account()
        let store = makeStore(
            account: account,
            transparentBalance: Zatoshi(1_010_000),
            priorityContent: .priority7,
            priorityContentRequested: .priority7,
            isOpen: false
        )

        await store.send(.shieldingProcessorStateChanged(.succeeded))
        await store.receive(\.closeAndCleanupBanner)
        await store.receive(\.closeBanner) {
            $0.priorityContent = nil
            $0.priorityContentRequested = nil
        }

        #expect(store.state.priorityContent == nil)
        #expect(store.state.priorityContentRequested == nil)
    }

    /// The pre-fix behaviour is preserved for the case it already handled: a banner actually on
    /// screen still closes on success.
    @Test func successStillClosesAShieldingBannerThatIsOnScreen() async {
        let account = Self.account()
        let store = makeStore(
            account: account,
            transparentBalance: Zatoshi(1_010_000),
            priorityContent: .priority7,
            isOpen: true
        )

        await store.send(.shieldingProcessorStateChanged(.succeeded))
        await store.receive(\.closeAndCleanupBanner)
        await store.receive(\.closeBanner) {
            $0.isOpen = false
            $0.priorityContent = nil
        }
    }

    /// A banner belonging to any OTHER priority is none of shielding's business.
    @Test func successLeavesANonShieldingBannerAlone() async {
        let account = Self.account()
        let store = makeStore(
            account: account,
            priorityContent: .priority8,
            isOpen: true
        )

        await store.send(.shieldingProcessorStateChanged(.succeeded))

        #expect(store.state.priorityContent == .priority8)
        #expect(store.state.isOpen)
    }

    // MARK: - The zero-amount gates

    /// Whatever claimed the slot, a shielding banner may not be SEATED for an amount the SDK cannot
    /// build a proposal for.
    @Test func aShieldingBannerIsNeverSeatedForAZeroBalance() async {
        let account = Self.account()
        let store = makeStore(account: account, transparentBalance: .zero)

        await store.send(.triggerPriority(.priority7)) {
            $0.priorityContentRequested = .priority7
        }
        await store.receive(\.openBannerRequest) {
            $0.priorityContentRequested = nil
        }

        #expect(store.state.priorityContent == nil)
    }

    /// Just under the threshold is the same case as zero — `proposeShielding` answers both with a
    /// nil proposal.
    @Test func aShieldingBannerIsNeverSeatedBelowTheShieldingThreshold() async {
        let account = Self.account()
        let store = makeStore(account: account, transparentBalance: Zatoshi(Self.threshold.amount - 1))

        await store.send(.triggerPriority(.priority7)) {
            $0.priorityContentRequested = .priority7
        }
        await store.receive(\.openBannerRequest) {
            $0.priorityContentRequested = nil
        }

        #expect(store.state.priorityContent == nil)
    }

    /// A real amount still gets its banner — the gate is about zero, not about shielding.
    @Test func aShieldingBannerIsSeatedForAShieldableBalance() async {
        let account = Self.account()
        let store = makeStore(account: account, transparentBalance: Self.threshold)

        await store.send(.triggerPriority(.priority7)) {
            $0.priorityContentRequested = .priority7
        }
        await store.receive(\.openBannerRequest) {
            $0.priorityContent = .priority7
        }
        await store.receive(\.openBanner) {
            $0.isOpen = true
        }
    }

    /// The second gate: the seat was granted up to `state.delay` seconds ago, so the amount is
    /// re-checked at the moment the banner would actually appear.
    @Test func aSeatedShieldingBannerDoesNotOpenIfItsBalanceWentToZeroFirst() async {
        let account = Self.account()
        let store = makeStore(
            account: account,
            transparentBalance: .zero,
            priorityContent: .priority7
        )

        await store.send(.openBanner)
        await store.receive(\.closeBanner) {
            $0.priorityContent = nil
        }

        #expect(!store.state.isOpen)
    }

    // MARK: - The single source of truth for the amount

    /// The whole cause in one assertion: `.succeeded` must not touch the displayed figure. It used
    /// to write `.zero`, which both rendered as "Shield 0.000" and answered the "is there anything
    /// to shield" comparison.
    @Test func successDoesNotWriteTheTransparentBalance() async {
        let account = Self.account()
        let store = makeStore(account: account, transparentBalance: Zatoshi(1_010_000))

        await store.send(.shieldingProcessorStateChanged(.succeeded))

        #expect(store.state.transparentBalance == Zatoshi(1_010_000))
    }

    /// The figure follows the SDK verbatim — including down to zero once the shield's spend is
    /// recorded, which is what actually retires the offer.
    @Test func theTransparentBalanceMirrorsWhateverTheSDKReports() async {
        let account = Self.account()
        let store = makeStore(account: account, transparentBalance: Zatoshi(1_010_000))

        await store.send(.synchronizerStateChanged(Self.syncState(account: account, unshielded: .zero))) {
            $0.transparentBalance = .zero
        }
    }

    /// Mirrored on EVERY emission, not only when the sync status transitions — a rising edge
    /// arriving on a quiet tick would otherwise be swallowed while the figure moved anyway.
    @Test func theTransparentBalanceMirrorsOnTicksThatDoNotChangeSyncStatus() async {
        let account = Self.account()
        let store = makeStore(account: account)
        let staleBalances = Self.staleBalances(account: account)
        store.dependencies.sdkSynchronizer = SDKSynchronizerClient.mocked(getAccountsBalances: { staleBalances })

        await store.send(.synchronizerStateChanged(Self.syncState(account: account, unshielded: .zero))) {
            $0.transparentBalance = .zero
        }
        // Same `syncStatus` (`.upToDate`), so the status-transition body is skipped entirely —
        // but the mirror and the offer arms run regardless.
        await store.send(.synchronizerStateChanged(Self.syncState(account: account, unshielded: Zatoshi(1_010_000)))) {
            $0.transparentBalance = Zatoshi(1_010_000)
        }
        await store.receive(\.shieldingOfferReevaluationRequested)
    }

    // MARK: - One funnel, one set of rules

    /// A transparent balance crossing the threshold asks the shared funnel rather than seating the
    /// banner outright.
    @Test func aRisingBalanceAsksTheOfferFunnelRatherThanSeatingTheBannerDirectly() async {
        let account = Self.account()
        let store = makeStore(account: account, transparentBalance: .zero)
        let staleBalances = Self.staleBalances(account: account)
        store.dependencies.sdkSynchronizer = SDKSynchronizerClient.mocked(getAccountsBalances: { staleBalances })

        await store.send(.synchronizerStateChanged(Self.syncState(account: account, unshielded: Zatoshi(1_010_000)))) {
            $0.transparentBalance = Zatoshi(1_010_000)
        }
        await store.receive(\.shieldingOfferReevaluationRequested)
    }

    /// No edge, no question: a balance that was already shieldable must not re-ask on every tick,
    /// or a dismissed banner would be re-litigated continuously.
    @Test func anAlreadyShieldableBalanceDoesNotReAskOnEveryTick() async {
        let account = Self.account()
        let store = makeStore(account: account, transparentBalance: Zatoshi(1_010_000))

        await store.send(.synchronizerStateChanged(Self.syncState(account: account, unshielded: Zatoshi(1_020_000)))) {
            $0.transparentBalance = Zatoshi(1_020_000)
        }

        #expect(store.state.priorityContentRequested == nil)
    }

    /// The funnel unification, stated: "Remind me later" is now binding on the SYNC route too. This
    /// route used to call `.triggerPriority(.priority7)` outright and consult no reminder at all.
    @Test func theSyncRouteHonoursTheRemindMeLaterBackoff() async {
        let account = Self.account()
        let store = makeStore(account: account, transparentBalance: .zero)
        let staleBalances = Self.staleBalances(account: account)
        store.dependencies.sdkSynchronizer = SDKSynchronizerClient.mocked(getAccountsBalances: { staleBalances })
        // Dismissed a moment ago — phase 1's two-day wait is nowhere near elapsed.
        store.dependencies.walletStorage = .noOp
        store.dependencies.walletStorage.exportShieldingReminder = { _ in
            ReminedMeTimestamp(timestamp: Date().timeIntervalSince1970, occurence: 1)
        }

        await store.send(.shieldingOfferReevaluationRequested(Zatoshi(1_010_000))) {
            $0.remindMeShieldedPhaseCounter = 1
        }
        await store.receive(\.transparentBalanceUpdated) {
            $0.transparentBalance = Zatoshi(1_010_000)
        }

        #expect(store.state.priorityContentRequested == nil)
        #expect(store.state.priorityContent == nil)
    }

    /// Never offered, never dismissed — phase 1 offers immediately, on either route.
    @Test func aFirstTimeShieldableBalanceIsOfferedOnTheSyncRoute() async {
        let account = Self.account()
        let store = makeStore(account: account, transparentBalance: .zero)
        let staleBalances = Self.staleBalances(account: account)
        store.dependencies.sdkSynchronizer = SDKSynchronizerClient.mocked(getAccountsBalances: { staleBalances })

        await store.send(.shieldingOfferReevaluationRequested(Zatoshi(1_010_000)))
        await store.receive(\.transparentBalanceUpdated) {
            $0.transparentBalance = Zatoshi(1_010_000)
        }
        await store.receive(\.triggerPriority) {
            $0.priorityContentRequested = .priority7
        }
    }

    /// The two routes differ in exactly one respect: what a DECLINE does. The ladder walks on...
    @Test func theLadderRouteWalksOnWhenThereIsNothingToShield() async {
        let account = Self.account()
        let store = makeStore(account: account)
        store.dependencies.sdkSynchronizer = SDKSynchronizerClient.mocked(getAccountsBalances: { [:] })

        await store.send(.evaluatePriority7)
        await store.receive(\.evaluatePriority75)
    }

    /// ...while the sync route stops, so a transparent deposit landing can never seat Tor or
    /// currency conversion as a side effect of asking about shielding.
    @Test func theSyncRouteStopsWhenThereIsNothingToShield() async {
        let account = Self.account()
        let store = makeStore(account: account)
        // No stub needed: the sync route decides from the figure it was handed, without a
        // wallet-DB read. An unimplemented `getAccountsBalances` would fail the test if it did one.
        await store.send(.shieldingOfferReevaluationRequested(.zero))

        #expect(store.state.priorityContent == nil)
        #expect(store.state.priorityContentRequested == nil)
    }

    // MARK: - Retiring an offer whose funds are gone

    /// The SDK reporting the balance gone is what retires a standing offer — no in-flight
    /// bookkeeping on this side, because the spend is recorded before the transaction is submitted.
    @Test func aStandingOfferIsRetiredWhenTheSDKReportsTheBalanceGone() async {
        let account = Self.account()
        let store = makeStore(
            account: account,
            transparentBalance: Zatoshi(1_010_000),
            priorityContent: .priority7,
            isOpen: true
        )

        await store.send(.synchronizerStateChanged(Self.syncState(account: account, unshielded: .zero))) {
            $0.transparentBalance = .zero
        }
        await store.receive(\.closeAndCleanupBanner)
        await store.receive(\.closeBanner) {
            $0.isOpen = false
            $0.priorityContent = nil
        }
    }

    /// A standing offer whose funds are still there just re-renders the new figure.
    @Test func aStandingOfferSurvivesABalanceThatIsStillShieldable() async {
        let account = Self.account()
        let store = makeStore(
            account: account,
            transparentBalance: Zatoshi(1_010_000),
            priorityContent: .priority7,
            isOpen: true
        )

        await store.send(.synchronizerStateChanged(Self.syncState(account: account, unshielded: Zatoshi(2_000_000)))) {
            $0.transparentBalance = Zatoshi(2_000_000)
        }

        #expect(store.state.priorityContent == .priority7)
        #expect(store.state.isOpen)
    }

    // MARK: - A shield already in flight is not re-offered

    /// Observed on device 2026-08-20: for a second or two after a successful shield the SDK reports
    /// the PRE-SHIELD `unshielded` again. That reads as a fresh rising edge and re-offered the very
    /// funds being shielded — the banner returning with the identical amount. The pending shielding
    /// transaction answers it, and being derived it clears itself when the transaction mines.
    @Test func aPendingShieldIsNotReOfferedWhenTheBalanceBouncesBack() async {
        let account = Self.account()
        let store = makeStore(account: account, transparentBalance: .zero)
        store.state.$transactions.withLock { $0 = [Self.shieldingTransaction(status: .shielding)] }

        await store.send(.shieldingOfferReevaluationRequested(Zatoshi(1_010_000)))

        #expect(store.state.priorityContentRequested == nil)
        #expect(store.state.priorityContent == nil)
    }

    /// The ladder's route declines the same way, and walks on to the next rung rather than stopping.
    @Test func theLadderWalksPastShieldingWhileAShieldIsPending() async {
        let account = Self.account()
        let store = makeStore(account: account, transparentBalance: Zatoshi(1_010_000))
        store.state.$transactions.withLock { $0 = [Self.shieldingTransaction(status: .shielding)] }
        // A decline WALKS ON, so the rungs past shielding run too and need a synchronizer.
        store.dependencies.sdkSynchronizer = SDKSynchronizerClient.mocked()

        await store.send(.evaluatePriority7)
        await store.receive(\.evaluatePriority75)
    }

    /// Once the shielding transaction is no longer pending the offer is available again — nothing
    /// to reset, because the suppression was never stored.
    @Test func theOfferReturnsOnceTheShieldingTransactionIsNoLongerPending() async {
        let account = Self.account()
        let store = makeStore(account: account, transparentBalance: .zero)
        store.state.$transactions.withLock { $0 = [Self.shieldingTransaction(status: .shielded)] }

        await store.send(.shieldingOfferReevaluationRequested(Zatoshi(1_010_000)))
        await store.receive(\.transparentBalanceUpdated) {
            $0.transparentBalance = Zatoshi(1_010_000)
        }
        await store.receive(\.triggerPriority) {
            $0.priorityContentRequested = .priority7
        }
    }

    /// Switching accounts drops the previous account's figure — the ladder restarted by the switch
    /// re-mirrors it for whichever account is now selected. Driven through a plain `Store`:
    /// `.walletAccountChanged` arms a long-lived migration state-stream publisher that a
    /// `TestStore` would flag as an unfinished effect.
    @Test func switchingAccountsClearsThePreviousAccountsBalance() async {
        let account = Self.account()
        var state = SmartBanner.State()
        state.$selectedWalletAccount.withLock { $0 = account }
        state.transparentBalance = Zatoshi(1_010_000)

        let store = Store(initialState: state) {
            SmartBanner()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.walletStorage = .noOp
        }

        store.send(.walletAccountChanged)

        #expect(store.transparentBalance == .zero)
    }
}
