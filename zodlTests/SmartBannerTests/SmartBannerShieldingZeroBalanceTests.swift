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
        unshielded: Zatoshi
    ) -> RedactableSynchronizerState {
        var syncState = SynchronizerState.zero
        syncState.syncStatus = .upToDate
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
        priorityContent: SmartBanner.State.PriorityContent? = nil,
        priorityContentRequested: SmartBanner.State.PriorityContent? = nil
    ) -> TestStore<SmartBanner.State, SmartBanner.Action> {
        var state = SmartBanner.State()
        state.$selectedWalletAccount.withLock { $0 = account }
        state.transparentBalance = transparentBalance
        state.priorityContent = priorityContent
        state.priorityContentRequested = priorityContentRequested

        let store = TestStore(initialState: state) {
            SmartBanner()
        }
        store.exhaustivity = .off
        store.dependencies.mainQueue = .immediate
        store.dependencies.walletStorage = .noOp
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
        await store.receive(\.transparentBalanceUpdated)

        #expect(store.state.priorityContentRequested == nil)
        #expect(store.state.priorityContent == nil)
    }

    @Test func pendingShieldIsNotReofferedWhenBalanceBouncesBack() async {
        let store = makeStore(account: Self.account())
        store.state.$transactions.withLock { $0 = [Self.pendingShieldingTransaction()] }

        await store.send(.shieldingOfferReevaluationRequested(Self.shieldableBalance))

        #expect(store.state.priorityContentRequested == nil)
        #expect(store.state.priorityContent == nil)
    }
}
