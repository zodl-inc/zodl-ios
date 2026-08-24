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
}
