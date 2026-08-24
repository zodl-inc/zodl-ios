//
//  SmartBannerShieldingOfferLifecycleTests.swift
//  zodlTests
//

import Foundation
import Testing
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) @MainActor struct SmartBannerShieldingOfferLifecycleTests {
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
        priorityContentRequested: SmartBanner.State.PriorityContent? = nil,
        hasDeferredShieldingOffer: Bool = false,
        isOpen: Bool = false
    ) -> TestStore<SmartBanner.State, SmartBanner.Action> {
        var state = SmartBanner.State()
        state.$selectedWalletAccount.withLock { $0 = account }
        state.transparentBalance = transparentBalance
        state.remindMeShieldedPhaseCounter = remindMeShieldedPhaseCounter
        state.priorityContent = priorityContent
        state.priorityContentRequested = priorityContentRequested
        state.hasDeferredShieldingOffer = hasDeferredShieldingOffer
        state.isOpen = isOpen

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

    /// A retraction can nil the seat while a scheduled `.openBanner` is still in flight; the
    /// stale open must not expand an empty banner shell.
    @Test func openBannerWithEmptySlotDoesNothing() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(account: Self.account())

            await store.send(.openBanner)

            #expect(store.state.isOpen == false)
        }
    }

    /// One tick can both drop the balance below threshold (retracting priority7) and carry a new
    /// sync error (seating priority2). The retraction's clean close is delivered through an async
    /// hop and must NOT wipe the error banner the same tick just seated — the error message
    /// comparison has already been consumed, so the banner would be lost for the session.
    @Test func sameTickRetractionDoesNotWipeTheFreshlySeatedErrorBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let account = Self.account()
            let store = makeStore(
                account: account,
                transparentBalance: Self.shieldableBalance,
                priorityContent: .priority7,
                priorityContentRequested: .priority7
            )

            await store.send(
                .synchronizerStateChanged(
                    Self.syncState(
                        account: account,
                        unshielded: .zero,
                        syncStatus: .error(ZcashError.synchronizerNotPrepared)
                    )
                )
            )
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == .priority2)
        }
    }

    /// A balance fetched for the previously selected account must not poison the new account's
    /// offer state — the account switch's own ladder re-walk covers the new account.
    @Test func staleFetchForAPreviousAccountIsDropped() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(account: Self.account())
            let previousAccountId = AccountUUID(id: [UInt8](repeating: 3, count: 16))

            await store.send(.shieldingBalanceFetched(previousAccountId, Self.shieldableBalance))

            #expect(store.state.transparentBalance == .zero)
            #expect(store.state.priorityContentRequested == nil)
        }
    }

    /// A terminal shielding outcome answers the offer, so the deferred-offer latch must fall with
    /// it — a mid-sync crossing armed before a Keystone `.proposal` would otherwise re-raise the
    /// banner during the signing flow.
    @Test func terminalOutcomeClearsTheDeferredOfferLatch() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(
                account: Self.account(),
                transparentBalance: Self.shieldableBalance,
                priorityContent: .priority7,
                priorityContentRequested: .priority7,
                hasDeferredShieldingOffer: true
            )

            await store.send(.shieldingProcessorStateChanged(.succeeded)) {
                $0.hasDeferredShieldingOffer = false
            }
            await store.finish()
            await store.skipReceivedActions(strict: false)
        }
    }

    /// The ladder's own fetch discovering a sub-threshold balance must retract a seated shielding
    /// banner exactly like the sync tick does — not leave it on screen showing the new, useless
    /// amount — and then continue the walk to the next lane.
    @Test func ladderFetchBelowThresholdRetractsTheSeatedBannerAndWalksDown() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let account = Self.account()
            let store = makeStore(
                account: account,
                transparentBalance: Self.shieldableBalance,
                priorityContent: .priority7,
                priorityContentRequested: .priority7
            )
            store.dependencies.walletStorage.exportTorSetupFlag = { nil }

            await store.send(.shieldingBalanceFetched(account.id, Zatoshi(50)))
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == .priority75)
        }
    }

    /// The same ladder retraction, but with the banner actually ON SCREEN (`isOpen == true`) —
    /// not merely seated behind the pre-open delay. A close routed through the deferred,
    /// generation-guarded `closeAndCleanupBanner` hop defers the successor's own seat behind the
    /// `openBannerRequest` reseat dance (`isOpen` branch), so the generation never bumps in time
    /// and the stale close can still land and wipe the `.priority75` request — this case must
    /// fail against a fix that only handles the not-yet-open seat.
    @Test func ladderFetchBelowThresholdRetractsAnOpenSeatedBannerAndWalksDown() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let account = Self.account()
            let store = makeStore(
                account: account,
                transparentBalance: Self.shieldableBalance,
                priorityContent: .priority7,
                priorityContentRequested: .priority7,
                isOpen: true
            )
            store.dependencies.walletStorage.exportTorSetupFlag = { nil }

            await store.send(.shieldingBalanceFetched(account.id, Zatoshi(50)))
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == .priority75)
            #expect(store.state.isOpen == true)
        }
    }

    /// The syncing banner outranks the shielding offer and may displace it — but the offer is
    /// still owed. Displacement arms the deferred-offer latch so the next up-to-date tick
    /// re-raises it through the normal request path.
    @Test func displacementByTheSyncingBannerReArmsTheOffer() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let account = Self.account()
            let store = makeStore(
                account: account,
                transparentBalance: Self.shieldableBalance,
                priorityContent: .priority7
            )

            await store.send(.triggerPriority(.priority4)) {
                $0.priorityContentRequested = .priority4
            }
            await store.receive(\.openBannerRequest) {
                $0.priorityContent = .priority4
                $0.hasDeferredShieldingOffer = true
            }
            await store.finish()
            await store.skipReceivedActions(strict: false)

            // The up-to-date tick both re-arms the reevaluation through the deferred-offer latch
            // and — pre-existing behavior, unrelated to this latch — closes the now-finished
            // syncing banner in the very same tick, so the re-raised offer claims the freed slot
            // immediately rather than waiting for a later tick.
            await store.send(.synchronizerStateChanged(Self.syncState(account: account, unshielded: Self.shieldableBalance)))
            await store.receive(\.shieldingOfferReevaluationRequested)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContentRequested == .priority7)
            #expect(store.state.priorityContent == .priority7)
            #expect(store.state.isOpen == true)
        }
    }

    /// A decline for a reason that can expire (a stored, not-yet-due reminder) must not consume
    /// the deferred edge: the latch stays armed so a later tick re-asks, and the offer fires the
    /// moment the reminder matures.
    @Test func notDueReminderDeclineKeepsTheLatchArmed() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let account = Self.account()
            let reminder = LockIsolated(
                ReminedMeTimestamp(timestamp: Date().timeIntervalSince1970, occurence: 1)
            )
            let store = makeStore(account: account)
            store.dependencies.walletStorage.exportShieldingReminder = { _ in reminder.value }

            await store.send(.synchronizerStateChanged(Self.syncState(account: account, unshielded: Self.shieldableBalance))) {
                $0.transparentBalance = Self.shieldableBalance
                $0.hasDeferredShieldingOffer = true
            }
            await store.receive(\.shieldingOfferReevaluationRequested) {
                $0.remindMeShieldedPhaseCounter = 1
            }
            #expect(store.state.hasDeferredShieldingOffer == true)
            #expect(store.state.priorityContentRequested == nil)

            reminder.setValue(
                ReminedMeTimestamp(timestamp: Date().timeIntervalSince1970 - 86_400 * 3, occurence: 1)
            )
            await store.send(.synchronizerStateChanged(Self.syncState(account: account, unshielded: Self.shieldableBalance)))
            await store.receive(\.shieldingOfferReevaluationRequested)
            await store.receive(\.triggerPriority) {
                $0.hasDeferredShieldingOffer = false
            }
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == .priority7)
        }
    }

    /// A stored-but-not-due reminder declines the offer; the ladder pass must hand the turn to
    /// the next lane instead of dying at lane 7 for the whole reminder window.
    @Test func notDueReminderContinuesTheLadderPass() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let account = Self.account()
            let store = makeStore(account: account, transparentBalance: Self.shieldableBalance)
            store.dependencies.walletStorage.exportShieldingReminder = { _ in
                ReminedMeTimestamp(timestamp: Date().timeIntervalSince1970, occurence: 1)
            }
            store.dependencies.walletStorage.exportTorSetupFlag = { nil }

            await store.send(.shieldingBalanceFetched(account.id, Self.shieldableBalance)) {
                $0.remindMeShieldedPhaseCounter = 1
            }
            await store.receive(\.evaluatePriority75)
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == .priority75)
        }
    }
}
