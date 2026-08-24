//
//  SmartBannerShieldingZeroBalanceTests.swift
//  zodlTests
//

import Foundation
import Testing
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) @MainActor struct SmartBannerShieldingZeroBalanceTests {
    private static let threshold = Zatoshi(100_000)
    private static let shieldableBalance = Zatoshi(1_010_000)

    private static func account() -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 7, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

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

    private static func pendingShieldingTransaction() -> TransactionState {
        TransactionState(
            fee: Zatoshi(10_000),
            id: "shielding",
            status: .shielding,
            zecAmount: shieldableBalance,
            isShieldingTransaction: true
        )
    }

    private func makeStore(
        account: WalletAccount,
        transparentBalance: Zatoshi = .zero,
        remindMeShieldedPhaseCounter: Int = 0,
        priorityContent: SmartBanner.State.PriorityContent? = nil,
        priorityContentRequested: SmartBanner.State.PriorityContent? = nil
    ) -> TestStore<SmartBanner.State, SmartBanner.Action> {
        var state = SmartBanner.State()
        state.$selectedWalletAccount.withLock { $0 = account }
        state.transparentBalance = transparentBalance
        state.remindMeShieldedPhaseCounter = remindMeShieldedPhaseCounter
        state.priorityContent = priorityContent
        state.priorityContentRequested = priorityContentRequested

        let store = TestStore(initialState: state) {
            SmartBanner()
        }
        store.exhaustivity = .off
        store.dependencies.mainQueue = .immediate
        store.dependencies.walletStorage = .noOp
        // `.noOp.exportTorSetupFlag()` deliberately returns `false` (not `nil` — see
        // WalletStorageTestKey.swift), so a decline that walks the ladder past priority7 falls
        // through evaluatePriority75 into evaluatePriority8's `sdkSynchronizer.latestState()`
        // read. Mock it so that unrelated hop doesn't record an "Unimplemented" issue.
        store.dependencies.sdkSynchronizer = .noOp
        return store
    }

    @Test func successRetractsASeatedShieldingBanner() async {
        let store = makeStore(
            account: Self.account(),
            transparentBalance: Self.shieldableBalance,
            priorityContent: .priority7,
            priorityContentRequested: .priority7
        )

        await store.send(.shieldingProcessorStateChanged(.succeeded))
        await store.receive(\.closeAndCleanupBanner)
        await store.receive(\.closeBanner) {
            $0.priorityContent = nil
            $0.priorityContentRequested = nil
        }
    }

    /// Reviewer-flagged gap (P1): `.nothingToShield` belongs beside `.succeeded` here. It is
    /// reachable from `BalancesStore.shieldFundsTapped` — a call site with no SmartBanner state of
    /// its own to close — so without this the banner would sit stale until the next sync tick
    /// happened to notice the balance was never shieldable.
    @Test func nothingToShieldRetractsASeatedShieldingBanner() async {
        let store = makeStore(
            account: Self.account(),
            transparentBalance: Self.shieldableBalance,
            priorityContent: .priority7,
            priorityContentRequested: .priority7
        )

        await store.send(.shieldingProcessorStateChanged(.nothingToShield))
        await store.receive(\.closeAndCleanupBanner)
        await store.receive(\.closeBanner) {
            $0.priorityContent = nil
            $0.priorityContentRequested = nil
        }
    }

    /// A priority7 request can be latched behind a higher-rank seated banner (the arbiter's rank
    /// check refuses without clearing the request). A terminal shielding outcome must clear only
    /// that latch — closing would tear down the unrelated banner actually on screen.
    @Test func terminalOutcomeClearsALatchedRequestWithoutClosingTheSeatedBanner() async {
        let store = makeStore(
            account: Self.account(),
            transparentBalance: Self.shieldableBalance,
            priorityContent: .priority4,
            priorityContentRequested: .priority7
        )

        await store.send(.shieldingProcessorStateChanged(.succeeded)) {
            $0.priorityContentRequested = nil
        }

        #expect(store.state.priorityContent == .priority4)
    }

    @Test(arguments: [Zatoshi.zero, Zatoshi(99_999)])
    func unshieldableBalanceNeverSeatsABanner(_ balance: Zatoshi) async {
        let store = makeStore(account: Self.account(), transparentBalance: balance)

        await store.send(.triggerPriority(.priority7)) {
            $0.priorityContentRequested = .priority7
        }
        await store.receive(\.openBannerRequest) {
            $0.priorityContentRequested = nil
        }

        #expect(store.state.priorityContent == nil)
    }

    @Test func shieldableBalanceStillSeatsABanner() async {
        let store = makeStore(account: Self.account(), transparentBalance: Self.threshold)

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

    @Test func seatedBannerDoesNotOpenAfterBalanceDropsToZero() async {
        let store = makeStore(
            account: Self.account(),
            transparentBalance: .zero,
            priorityContent: .priority7
        )

        await store.send(.openBanner)
        await store.receive(\.closeBanner) {
            $0.priorityContent = nil
        }

        #expect(!store.state.isOpen)
    }

    @Test func unchangedSyncStatusBalanceUpdateHonoursReminder() async {
        let account = Self.account()
        let store = makeStore(account: account)
        store.dependencies.walletStorage.exportShieldingReminder = { _ in
            ReminedMeTimestamp(timestamp: Date().timeIntervalSince1970, occurence: 1)
        }

        await store.send(.synchronizerStateChanged(Self.syncState(account: account, unshielded: .zero)))
        await store.send(
            .synchronizerStateChanged(Self.syncState(account: account, unshielded: Self.shieldableBalance))
        ) {
            $0.transparentBalance = Self.shieldableBalance
        }
        await store.receive(\.shieldingOfferReevaluationRequested) {
            $0.remindMeShieldedPhaseCounter = 1
        }

        #expect(store.state.priorityContentRequested == nil)
        #expect(store.state.priorityContent == nil)
    }

    /// A transparent deposit that crosses the threshold while sync is still running must produce
    /// the offer once sync completes. The per-tick balance write consumes the crossing edge, so
    /// without a latch the mid-sync deposit is silently lost for the whole session.
    @Test func depositDuringSyncOffersOnceSyncCompletes() async {
        let account = Self.account()
        let store = makeStore(account: account)

        await store.send(
            .synchronizerStateChanged(Self.syncState(account: account, unshielded: Self.shieldableBalance, syncStatus: .syncing(0.5, false)))
        ) {
            $0.transparentBalance = Self.shieldableBalance
        }

        await store.send(.synchronizerStateChanged(Self.syncState(account: account, unshielded: Self.shieldableBalance)))
        await store.receive(\.shieldingOfferReevaluationRequested)
        await store.receive(\.triggerPriority)
        // `store.state` only reflects actions pulled off the received-actions queue — the seat
        // itself happens one hop further, in `.openBannerRequest`. Drain the rest of the cascade
        // before reading final state instead of asserting the remaining hops by name.
        await store.finish()
        await store.skipReceivedActions(strict: false)

        #expect(store.state.priorityContent == .priority7)
    }

    /// A tick that BOTH completes the sync AND carries the qualifying balance must not lose the
    /// offer to the status machinery's early returns — here, the seated syncing banner's own
    /// close, which used to exit the function before the re-offer could fire.
    @Test func offerSurvivesTheTickThatClosesTheSyncingBanner() async {
        let account = Self.account()
        let store = makeStore(account: account, priorityContent: .priority4)

        await store.send(.synchronizerStateChanged(Self.syncState(account: account, unshielded: Self.shieldableBalance))) {
            $0.transparentBalance = Self.shieldableBalance
        }
        await store.receive(\.shieldingOfferReevaluationRequested)
        await store.receive(\.triggerPriority)
        // `.closeAndCleanupBanner` races the shielding chain above — both are legs of the same
        // `.merge` in `.synchronizerStateChanged`, so their relative arrival order on the
        // received-actions queue is not guaranteed, and naming it here as a third `.receive`
        // can starve on an action already consumed while skipping ahead to `.triggerPriority`.
        // Its own effects (`.closeBanner`, the resulting `.openBannerRequest`) still run
        // independently of whether this test observes the action by name — drain and read the
        // settled state instead of asserting a cross-branch order that doesn't exist.
        await store.finish()
        await store.skipReceivedActions(strict: false)

        #expect(store.state.priorityContent == .priority7)
    }

    @Test func pendingShieldIsNotReofferedWhenBalanceBouncesBack() async {
        let store = makeStore(account: Self.account(), transparentBalance: Self.shieldableBalance)
        store.state.$transactions.withLock { $0 = [Self.pendingShieldingTransaction()] }

        await store.send(.shieldingOfferReevaluationRequested)

        #expect(store.state.priorityContentRequested == nil)
        #expect(store.state.priorityContent == nil)
    }

    /// The ladder's balance fetch failing must walk the pass down, exactly as an unshieldable
    /// balance does — never seat an offer on whatever stale figure state still holds.
    @Test func fetchFailureWalksDownToTheNextLane() async {
        let store = makeStore(account: Self.account(), transparentBalance: Self.shieldableBalance)

        await store.send(.shieldingBalanceFetched(nil))
        await store.receive(\.evaluatePriority75)
    }

    /// A successful shield resets the stored reminder; the phase counter must reset with it or
    /// the help sheet describes a phase ("remind me in a month") the next dismissal won't honor.
    @Test func reminderClearedAfterShieldResetsPhaseCounter() async {
        let store = makeStore(
            account: Self.account(),
            transparentBalance: Self.shieldableBalance,
            remindMeShieldedPhaseCounter: 3
        )

        await store.send(.shieldingOfferReevaluationRequested) {
            $0.remindMeShieldedPhaseCounter = 0
        }
        await store.receive(\.triggerPriority)
    }
}
