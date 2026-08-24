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
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
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
    }

    /// Reviewer-flagged gap (P1): `.nothingToShield` belongs beside `.succeeded` here. It is
    /// reachable from `BalancesStore.shieldFundsTapped` — a call site with no SmartBanner state of
    /// its own to close — so without this the banner would sit stale until the next sync tick
    /// happened to notice the balance was never shieldable.
    @Test func nothingToShieldRetractsASeatedShieldingBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
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
    }

    /// A priority7 request can be latched behind a higher-rank seated banner (the arbiter's rank
    /// check refuses without clearing the request). A terminal shielding outcome must clear only
    /// that latch — closing would tear down the unrelated banner actually on screen.
    @Test func terminalOutcomeClearsALatchedRequestWithoutClosingTheSeatedBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
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
    }

    /// An unshieldable balance must never seat the shielding banner — and because the request
    /// came from a ladder pass, the pass continues to the next lane (the test clears the stored
    /// Tor-setup flag so priority75 seats deterministically) instead of dying with nothing shown.
    @Test(arguments: [Zatoshi.zero, Zatoshi(99_999)])
    func unshieldableBalanceSeatsTheNextLaneInstead(_ balance: Zatoshi) async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(account: Self.account(), transparentBalance: balance)
            store.dependencies.walletStorage.exportTorSetupFlag = { nil }

            await store.send(.triggerPriority(.priority7)) {
                $0.priorityContentRequested = .priority7
            }
            await store.receive(\.openBannerRequest) {
                $0.priorityContentRequested = nil
            }
            await store.receive(\.evaluatePriority75)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == .priority75)
        }
    }

    @Test func shieldableBalanceStillSeatsABanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
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
    }

    /// The balance dropped between seating and opening: the stale offer closes, and — same
    /// ladder-pass rule — the walk continues, so the next lane's banner opens in its place.
    @Test func seatedBannerClosesAndHandsOverAfterBalanceDropsToZero() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(
                account: Self.account(),
                transparentBalance: .zero,
                priorityContent: .priority7
            )
            store.dependencies.walletStorage.exportTorSetupFlag = { nil }

            await store.send(.openBanner)
            await store.receive(\.closeBanner) {
                $0.priorityContent = nil
            }
            await store.receive(\.evaluatePriority75)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == .priority75)
        }
    }

    @Test func unchangedSyncStatusBalanceUpdateHonoursReminder() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
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
    }

    /// A transparent deposit that crosses the threshold while sync is still running must produce
    /// the offer once sync completes. The per-tick balance write consumes the crossing edge, so
    /// without a latch the mid-sync deposit is silently lost for the whole session.
    @Test func depositDuringSyncOffersOnceSyncCompletes() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
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
    }

    /// A tick that BOTH completes the sync AND carries the qualifying balance must not lose the
    /// offer to the status machinery's early returns — here, the seated syncing banner's own
    /// close, which used to exit the function before the re-offer could fire.
    @Test func offerSurvivesTheTickThatClosesTheSyncingBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
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
    }

    @Test func pendingShieldIsNotReofferedWhenBalanceBouncesBack() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(account: Self.account(), transparentBalance: Self.shieldableBalance)
            store.state.$transactions.withLock { $0 = [Self.pendingShieldingTransaction()] }

            await store.send(.shieldingOfferReevaluationRequested)

            #expect(store.state.priorityContentRequested == nil)
            #expect(store.state.priorityContent == nil)
        }
    }

    /// The ladder's balance fetch failing must walk the pass down, exactly as an unshieldable
    /// balance does — never seat an offer on whatever stale figure state still holds.
    @Test func fetchFailureWalksDownToTheNextLane() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(account: Self.account(), transparentBalance: Self.shieldableBalance)

            await store.send(.shieldingBalanceFetched(Self.account().id, nil))
            await store.receive(\.evaluatePriority75)
        }
    }

    /// A successful shield resets the stored reminder; the phase counter must reset with it or
    /// the help sheet describes a phase ("remind me in a month") the next dismissal won't honor.
    @Test func reminderClearedAfterShieldResetsPhaseCounter() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
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

    /// A latched request from a lane WITHOUT a seat-time validity rule must NOT survive a clean
    /// close: e.g. a priority1 (no connection) request latched behind the migration banner
    /// during a network blip would otherwise seat a phantom offline banner — with no rule to
    /// invalidate it — once migration closes, blocking every lower lane for the session.
    @Test func staleRulelessRequestDoesNotSurviveACleanClose() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(
                account: Self.account(),
                transparentBalance: Self.shieldableBalance,
                priorityContent: .priorityMigration,
                priorityContentRequested: .priority1
            )

            await store.send(.closeBanner(true)) {
                $0.priorityContent = nil
                $0.priorityContentRequested = nil
            }
            await store.receive(\.openBannerRequest)

            #expect(store.state.priorityContent == nil)
        }
    }

    /// The exhaustive switch's negative half: a failure outcome is not a terminal "offer is
    /// stale" signal — the funds are still unshielded, so the offer must stay.
    @Test func failureOutcomesKeepTheSeatedShieldingBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(
                account: Self.account(),
                transparentBalance: Self.shieldableBalance,
                priorityContent: .priority7,
                priorityContentRequested: .priority7
            )

            await store.send(.shieldingProcessorStateChanged(.failed("boom".toZcashError())))
            await store.send(.shieldingProcessorStateChanged(.grpc))

            #expect(store.state.priorityContent == .priority7)
            #expect(store.state.priorityContentRequested == .priority7)
        }
    }

    /// An account switch abandons the old account's offer state: the deferred-offer latch, any
    /// latched priority7 request, and the displayed balance all belong to the account that
    /// armed them.
    @Test func accountSwitchClearsShieldingOfferState() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let account = Self.account()
            let store = makeStore(
                account: account,
                priorityContentRequested: .priority7
            )

            await store.send(
                .synchronizerStateChanged(Self.syncState(account: account, unshielded: Self.shieldableBalance, syncStatus: .syncing(0.5, false)))
            ) {
                $0.transparentBalance = Self.shieldableBalance
                $0.hasDeferredShieldingOffer = true
            }

            await store.send(.walletAccountChanged) {
                $0.transparentBalance = .zero
                $0.hasDeferredShieldingOffer = false
                $0.priorityContentRequested = nil
                $0.remindMeShieldedPhaseCounter = 0
            }
        }
    }
}
