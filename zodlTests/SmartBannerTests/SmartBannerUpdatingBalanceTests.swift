//
//  SmartBannerUpdatingBalanceTests.swift
//  zodlTests
//
//  Covers the priority5 "Updating Balance" banner (MOB-1585): after a send, the shielded
//  spendable balance can legitimately read 0 while the shielded total stays > 0 (inputs
//  pending-spent, change awaiting confirmations). This exercises the trigger/close wiring in
//  `.synchronizerStateChanged`, the `evaluatePriority5` cascade fallback, and the
//  `.walletAccountChanged` balance reset (Features/SmartBanner/SmartBannerStore.swift).
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized: drives `SmartBanner.State`'s `@Shared(.inMemory(.selectedWalletAccount))` state,
// process-global storage. Each test additionally scopes a fresh `InMemoryStorage()` via
// `withDependencies` so parallel suites can't clobber that shared state either — the same
// belt-and-suspenders approach used by SmartBannerTests.swift's Ironwood-balance test.
@Suite(.serialized) @MainActor struct SmartBannerUpdatingBalanceTests {
    private static let account = WalletAccount(
        Account(
            id: AccountUUID(id: [UInt8](repeating: 0x05, count: 16)),
            name: "Zodl",
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        )
    )

    /// Spendable 0, change pending confirmation > 0 — the post-send state this feature exists to
    /// surface: shielded total > 0 (inputs pending-spent, change awaiting confirmations) but none
    /// of it is spendable yet.
    private static let pendingBalance = AccountBalance(
        saplingBalance: PoolBalance(
            spendableValue: Zatoshi(0),
            changePendingConfirmation: Zatoshi(50_000),
            valuePendingSpendability: Zatoshi(0)
        ),
        orchardBalance: .zero,
        unshielded: Zatoshi(0)
    )

    /// Spendable > 0 — the balance has recovered.
    private static let healthyBalance = AccountBalance(
        saplingBalance: PoolBalance(spendableValue: Zatoshi(100_000), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
        orchardBalance: .zero,
        unshielded: Zatoshi(0)
    )

    /// All-transparent wallet: shielded spendable AND shielded total are both zero, so the zero
    /// spendable reading is simply reality (no shielded funds at all), not a pending-confirmation
    /// artifact. That state belongs to priority7 (shielding), not priority5. `unshielded` is kept
    /// below the (test default 100_000) shielding threshold so it doesn't also trigger priority7.
    private static let transparentOnlyBalance = AccountBalance(
        saplingBalance: .zero,
        orchardBalance: .zero,
        unshielded: Zatoshi(1_000)
    )

    private static func tick(_ status: SyncStatus, balance: AccountBalance) -> RedactableSynchronizerState {
        var state = SynchronizerState.zero
        state.syncStatus = status
        state.accountsBalances = [account.id: balance]
        return state.redacted
    }

    private func makeStore(
        configureDependencies: (inout DependencyValues) -> Void = { _ in },
        modify: (inout SmartBanner.State) -> Void = { _ in }
    ) -> TestStore<SmartBanner.State, SmartBanner.Action> {
        var state = SmartBanner.State()
        state.$selectedWalletAccount.withLock { $0 = Self.account }
        modify(&state)

        let store = TestStore(initialState: state) {
            SmartBanner()
        } withDependencies: {
            $0.mainQueue = .immediate
            configureDependencies(&$0)
        }
        store.exhaustivity = .off
        return store
    }

    // MARK: - 1. Trigger on a non-syncing tick with no banner open

    @Test func pendingBalanceOnUpToDateTickTriggersPriority5AndOpensBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()

            await store.send(.synchronizerStateChanged(Self.tick(.upToDate, balance: Self.pendingBalance)))
            await store.receive(\.triggerPriority, .priority5)
            await store.receive(\.openBannerRequest)
            await store.receive(\.openBanner)

            #expect(store.state.priorityContent == .priority5)
            #expect(store.state.isOpen)
        }
    }

    // MARK: - 2. No trigger while syncing

    /// Non-syncing ticks own the priority5 trigger; a `.syncing` tick must defer to whichever
    /// restoring/syncing banner (priority3/4) owns the display during an active sync.
    @Test func pendingBalanceOnSyncingTickDoesNotTrigger() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()

            await store.send(.synchronizerStateChanged(Self.tick(.syncing(0.5, false), balance: Self.pendingBalance)))

            #expect(store.state.priorityContentRequested == nil)
            #expect(store.state.priorityContent == nil)
        }
    }

    // MARK: - 3. No trigger while a higher-priority banner is showing

    /// A generic sync error (rather than `.upToDate`) reaches the shared balance-check block
    /// without being intercepted by `.upToDate`'s own unconditional close of priority3/45/4 — so
    /// this actually exercises the rawValue guard on the trigger, not that unrelated early return.
    /// `lastKnownErrorMessage` is pre-matched to the tick's own message so the reducer's
    /// different-error check (which would otherwise trigger priority2 first) is a no-op. (`.stopped`
    /// is avoided here: the SDK's hand-written `SyncStatus.==` has no `.stopped` case and falls to
    /// `default: false`, so `.stopped` never equals itself — it would spuriously fail TestStore's
    /// own state-diffing regardless of this test's own assertions.)
    @Test func pendingBalanceDoesNotOverrideRestoringBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let genericError = SyncStatus.error(ZcashError.compactBlockProcessorCritical)
            let store = makeStore(modify: { state in
                state.priorityContent = .priority3
                state.priorityContentRequested = .priority3
                state.lastKnownErrorMessage = SyncStatusSnapshot.snapshotFor(state: genericError).message
            })

            await store.send(.synchronizerStateChanged(Self.tick(genericError, balance: Self.pendingBalance)))

            #expect(store.state.priorityContentRequested == .priority3)
            #expect(store.state.priorityContent == .priority3)
        }
    }

    // MARK: - 4. No trigger for healthy or all-transparent balances

    @Test func healthyOrTransparentOnlyBalanceDoesNotTrigger() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let healthyStore = makeStore()
            await healthyStore.send(.synchronizerStateChanged(Self.tick(.upToDate, balance: Self.healthyBalance)))
            #expect(healthyStore.state.priorityContentRequested == nil)

            let transparentStore = makeStore()
            await transparentStore.send(.synchronizerStateChanged(Self.tick(.upToDate, balance: Self.transparentOnlyBalance)))
            #expect(transparentStore.state.priorityContentRequested == nil)
        }
    }

    // MARK: - 5. Recovery closes and cleans up the banner

    @Test func balanceRecoveryClosesAndCleansUpPriority5Banner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(modify: { state in
                state.priorityContent = .priority5
                state.priorityContentRequested = .priority5
                state.isOpen = true
            })

            await store.send(.synchronizerStateChanged(Self.tick(.upToDate, balance: Self.healthyBalance)))
            await store.receive(\.closeAndCleanupBanner)
            await store.receive(\.closeBanner)
            await store.receive(\.openBannerRequest)

            #expect(store.state.priorityContent == nil)
            #expect(store.state.priorityContentRequested == nil)
            #expect(store.state.isOpen == false)
        }
    }

    // MARK: - 6. Still-pending balance keeps the banner open, no duplicate trigger

    @Test func stillPendingBalanceKeepsPriority5BannerOpen() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(modify: { state in
                state.priorityContent = .priority5
                state.priorityContentRequested = .priority5
                state.isOpen = true
            })

            await store.send(.synchronizerStateChanged(Self.tick(.upToDate, balance: Self.pendingBalance)))

            #expect(store.state.priorityContent == .priority5)
            #expect(store.state.priorityContentRequested == .priority5)
            #expect(store.state.isOpen)
        }
    }

    // MARK: - 7. Replaces a lower-priority banner

    @Test func pendingBalanceReplacesShieldingBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(modify: { state in
                state.priorityContent = .priority7
                state.priorityContentRequested = .priority7
                state.isOpen = true
            })

            await store.send(.synchronizerStateChanged(Self.tick(.upToDate, balance: Self.pendingBalance)))
            await store.receive(\.triggerPriority, .priority5)
            // `openBannerRequest` finds a lower-priority banner already open, so it closes it
            // first (`closeBanner`) and re-runs `openBannerRequest` before it can actually swap in
            // priority5 — see SmartBannerStore.swift's `openBannerRequest`/`closeBanner` pair.
            await store.receive(\.openBannerRequest)
            await store.receive(\.closeBanner)
            await store.receive(\.openBannerRequest)
            await store.receive(\.openBanner)

            #expect(store.state.priorityContent == .priority5)
            #expect(store.state.isOpen)
        }
    }

    // MARK: - 8. Account switch resets the stale per-account balance

    @Test func walletAccountChangedResetsSpendableBalance() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = SmartBanner.State()
            state.spendableBalance = Zatoshi(50_000)
            state.remindMeShieldedPhaseCounter = 2
            // No account selected: the ladder walk this action re-runs (`.evaluatePriority1` ->
            // ... -> `.evaluatePriority7`) then short-circuits at each account-dependent guard
            // without touching any other dependency, so nothing else needs stubbing here.
            state.$selectedWalletAccount.withLock { $0 = nil }

            let store = TestStore(initialState: state) {
                SmartBanner()
            } withDependencies: {
                $0.mainQueue = .immediate
            }
            store.exhaustivity = .off

            await store.send(.walletAccountChanged) {
                $0.remindMeShieldedPhaseCounter = 0
                $0.spendableBalance = Zatoshi(0)
            }
        }
    }

    // MARK: - 9. evaluatePriority5 cascade

    @Test func evaluatePriority5TriggersOnPendingBalanceFromTheSDK() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            // Captured into locals before crossing into the `@Sendable` closure below: `account`/
            // `pendingBalance` are `@MainActor`-isolated statics (members of this `@MainActor`
            // suite), and `getAccountsBalances`'s closure type isn't actor-isolated.
            let account = Self.account
            let pendingBalance = Self.pendingBalance
            // `walletStorage` is stubbed defensively: against the unfixed reducer this cascades
            // into `.evaluatePriority7`, which reads `walletStorage.exportShieldingReminder`.
            let store = makeStore(configureDependencies: {
                $0.sdkSynchronizer = .mocked(getAccountsBalances: { [account.id: pendingBalance] })
                $0.walletStorage = .noOp
            })

            await store.send(.evaluatePriority5)
            await store.receive(\.triggerPriority, .priority5)
        }
    }

    @Test func evaluatePriority5FallsThroughToPriority6OnHealthyBalanceFromTheSDK() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let account = Self.account
            let healthyBalance = Self.healthyBalance
            // `walletStorage` is stubbed because a healthy balance means this doesn't stop at
            // `.evaluatePriority6` — the ladder walk continues into `.evaluatePriority7` in the
            // background, which reads `walletStorage.exportShieldingReminder`.
            let store = makeStore(configureDependencies: {
                $0.sdkSynchronizer = .mocked(getAccountsBalances: { [account.id: healthyBalance] })
                $0.walletStorage = .noOp
            })

            await store.send(.evaluatePriority5)
            await store.receive(\.evaluatePriority6)
        }
    }
}
