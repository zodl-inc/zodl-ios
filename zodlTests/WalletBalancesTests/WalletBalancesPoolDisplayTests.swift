//
//  WalletBalancesPoolDisplayTests.swift
//  zodlTests
//
//  MOB-1661: Home renders the SDK's per-pool wallet summary directly. Transfer-engine state must
//  not adjust those values while a migration transaction is pending.
//

import Combine
import ComposableArchitecture
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct WalletBalancesPoolDisplayTests {
    @MainActor @Test func poolFiguresUseRawSDKBalances() async {
        let store = makeStore()
        let balance = fullPoolAccountBalance()

        await store.send(.balanceUpdated(balance))

        #expect(store.state.ironwoodPoolBalance == balance.ironwoodBalance.total())
        #expect(store.state.orchardPoolBalance == balance.orchardBalance.total())
        #expect(store.state.saplingPoolBalance == balance.saplingBalance.total())
        #expect(store.state.transparentBalance == balance.unshielded)
        #expect(store.state.shieldedBalance == balance.shieldedSpendableValue)
        #expect(store.state.shieldedWithPendingBalance == balance.shieldedTotal())
        #expect(store.state.totalBalance == balance.shieldedTotal() + balance.unshielded + balance.awaitingResolution)
    }

    @MainActor @Test func poolBalancesSumToTotal() async {
        let store = makeStore()
        await store.send(.balanceUpdated(fullPoolAccountBalance()))

        let sum = store.state.saplingPoolBalance
            + store.state.orchardPoolBalance
            + store.state.ironwoodPoolBalance
            + store.state.transparentPoolBalance
        #expect(sum == store.state.totalBalance)
    }

    /// Exact physical-device regression values: Home must preserve the SDK snapshot instead of
    /// subtracting a transfer-sized correction based on migration status.
    @MainActor @Test func migrationStatusDoesNotRewriteSDKPoolValues() async {
        let store = makeStore()
        let balance = AccountBalance(
            saplingBalance: .zero,
            orchardBalance: PoolBalance(
                spendableValue: Zatoshi(722_845_000),
                changePendingConfirmation: .zero,
                valuePendingSpendability: .zero
            ),
            ironwoodBalance: PoolBalance(
                spendableValue: Zatoshi(277_000_000),
                changePendingConfirmation: .zero,
                valuePendingSpendability: .zero
            ),
            unshielded: .zero,
            awaitingResolution: .zero
        )

        await store.send(.balanceUpdated(balance))

        #expect(store.state.orchardPoolBalance == Zatoshi(722_845_000))
        #expect(store.state.ironwoodPoolBalance == Zatoshi(277_000_000))
        #expect(store.state.orchardPoolBalance + store.state.ironwoodPoolBalance == Zatoshi(999_845_000))
    }

    /// A migration snapshot still requests a fresh SDK balance, so pool cards move promptly when
    /// the wallet summary itself changes.
    @MainActor @Test func snapshotEventTriggersBalanceRefresh() async {
        let snapshotSubject = PassthroughSubject<MigrationViewSnapshot?, Never>()
        let account = WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 1, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )

        var state = WalletBalances.State()
        state.$selectedWalletAccount.withLock { $0 = account }

        let store = TestStore(initialState: state) {
            WalletBalances()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            $0.exchangeRate = .noOp
            $0.sdkSynchronizer = .noOp
            var manager = MigrationManagerClient.noOp
            manager.migrationSnapshotEvents = { _ in snapshotSubject.eraseToAnyPublisher() }
            $0.migrationManager = manager
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.updateBalances)

        snapshotSubject.send(MigrationViewSnapshot.empty)
        await store.receive(\.updateBalances)

        await store.send(.onDisappear)
    }

    private func fullPoolAccountBalance() -> AccountBalance {
        AccountBalance(
            saplingBalance: PoolBalance(
                spendableValue: Zatoshi(100),
                changePendingConfirmation: Zatoshi(10),
                valuePendingSpendability: Zatoshi(20),
                lockedValue: Zatoshi(3)
            ),
            orchardBalance: PoolBalance(
                spendableValue: Zatoshi(200),
                changePendingConfirmation: Zatoshi(30),
                valuePendingSpendability: Zatoshi(40),
                lockedValue: Zatoshi(7)
            ),
            ironwoodBalance: PoolBalance(
                spendableValue: Zatoshi(300),
                changePendingConfirmation: Zatoshi(50),
                valuePendingSpendability: Zatoshi(60),
                lockedValue: Zatoshi(11)
            ),
            unshielded: Zatoshi(5),
            awaitingResolution: Zatoshi(1)
        )
    }

    @MainActor
    private func makeStore() -> TestStoreOf<WalletBalances> {
        let store = TestStore(initialState: WalletBalances.State()) {
            WalletBalances()
        } withDependencies: {
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
            $0.migrationManager = .noOp
        }
        store.exhaustivity = .off
        return store
    }
}
