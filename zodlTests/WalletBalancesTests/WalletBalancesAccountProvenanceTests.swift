//
//  WalletBalancesAccountProvenanceTests.swift
//  zodlTests
//
//  MOB-1862: `WalletBalances.State.balanceUpdated` (a plain `AccountBalance` with no account or
//  request identity) let a balance read for one account answer for whichever account happened to
//  be selected by the time the read landed. A slow `getLocalAccountBalances()` call started for
//  account A, resolving after the user had already switched to account B, would overwrite B's
//  figures with A's -- silently, with no error surfaced anywhere. A second race lived alongside
//  it: two `.updateBalances` dispatches for the SAME account, the earlier one answering after the
//  later one already has, could still let the stale answer win (last-writer-wins on arrival order,
//  not on which request was actually current).
//
//  The fix attributes every `.balanceUpdated` to the account it was read for AND the request that
//  asked for it -- `WalletBalancesStore.swift`'s `.balanceUpdated(AccountBalance, AccountUUID,
//  Int)` and `State.balanceRequestGeneration`. The handler drops anything whose account no longer
//  matches the current selection or whose generation is not the current one. `.updateBalances`
//  also re-derives `spendability` synchronously, before its own read has any chance to land -- a
//  switch to an account with no published balance yet must not go on showing the PREVIOUS
//  account's spendability for however long that read takes.
//
//  Mirrors `WalletBalancesMaskedSpendableTests.swift`'s established pattern for this directory:
//  `TestStore` with `$0.defaultInMemoryStorage = InMemoryStorage()` per test, and the shared
//  `selectedWalletAccount` slot pinned via `state.$selectedWalletAccount.withLock`. The parked-read
//  mechanics reuse `TestSupport/TestSignals.swift`'s `ResumableGate`/`SignalledRecords`, the same
//  event-driven, no-clock primitives `RootTransactionsCoalescingTests.swift` uses to hold a mocked
//  dependency open on a gate and count calls.
//
//  `.serialized`: constructing/driving `WalletBalances.State` touches the process-global
//  `@Shared(.inMemory(.selectedWalletAccount))` key, same precedent as
//  `WalletBalancesMaskedSpendableTests.swift`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct WalletBalancesAccountProvenanceTests {
    private static func walletAccount(idByte: UInt8) -> WalletAccount {
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

    /// A full-value balance -- shielded equals total -- so `spendability` derives to `.everything`
    /// once it is published for the currently selected account.
    private static func fullyOwnedBalance(_ shielded: Zatoshi) -> AccountBalance {
        AccountBalance(
            saplingBalance: .zero,
            orchardBalance: PoolBalance(spendableValue: shielded, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            ironwoodBalance: .zero,
            unshielded: .zero,
            awaitingResolution: .zero
        )
    }

    // MARK: - (1) A delayed read for the account just left must never answer for the new one

    /// Account A's read is parked on a gate; the user switches to B before it resolves. Releasing
    /// it must not let A's figures land on B's screen.
    @MainActor @Test func aDelayedBalanceForThePreviousAccountIsRejectedAfterASwitch() async throws {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let accountA = Self.walletAccount(idByte: 40)
            let accountB = Self.walletAccount(idByte: 41)
            let balanceA = Self.fullyOwnedBalance(Zatoshi(500))
            let gate = ResumableGate()

            var state = WalletBalances.State()
            state.$selectedWalletAccount.withLock { $0 = accountA }
            let store = TestStore(initialState: state) {
                WalletBalances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
                $0.sdkSynchronizer = .mocked(
                    latestState: { SynchronizerState.zero },
                    getLocalAccountBalances: {
                        await gate.wait()
                        return [accountA.id: balanceA]
                    }
                )
            }
            store.exhaustivity = .off

            let read = await store.send(.updateBalances)

            // Switch to B while A's read is still parked on the gate.
            store.state.$selectedWalletAccount.withLock { $0 = accountB }

            gate.open()
            // `.receive` is what actually applies a effect-sent action's resulting state to
            // `store.state` -- `finish()` alone only waits for the effect's task to physically
            // complete, it does not drain the action itself (`TestStore`'s `.receive`/exhaustivity
            // machinery does that).
            await store.receive(\.balanceUpdated)
            await read.finish()

            #expect(!store.state.hasConcreteBalance, "nothing has been published for B yet")
            #expect(store.state.shieldedBalance == .zero, "A's amounts must not be stored for B")
        }
    }

    // MARK: - (2) The new account's own, non-conflicting result still becomes concrete

    /// The positive counterpart of the test above: B requests and receives its OWN balance, with
    /// no switch or stale read involved. This path was never broken -- it guards against the fix
    /// over-correcting into rejecting legitimate, matching responses too.
    @MainActor @Test func theNewAccountsOwnResultBecomesConcrete() async throws {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let accountB = Self.walletAccount(idByte: 46)
            let balanceB = Self.fullyOwnedBalance(Zatoshi(750))

            var state = WalletBalances.State()
            state.$selectedWalletAccount.withLock { $0 = accountB }
            let store = TestStore(initialState: state) {
                WalletBalances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
                $0.sdkSynchronizer = .mocked(
                    latestState: { SynchronizerState.zero },
                    getLocalAccountBalances: { [accountB.id: balanceB] }
                )
            }
            store.exhaustivity = .off

            await store.send(.updateBalances)
            await store.receive(\.balanceUpdated)

            #expect(store.state.hasConcreteBalance)
            #expect(store.state.shieldedBalance == balanceB.shieldedSpendableValue)
            #expect(store.state.spendability == .everything)
        }
    }

    // MARK: - (3) A stale request's answer must not overwrite a fresher one, even for the SAME account

    /// A→B→A: the first request (generation 1, for A) is parked; two more requests land and
    /// resolve immediately before it is released -- the second for B (which answers nothing), the
    /// third back on A (generation 3, with a fresh figure). Releasing the first must not let its
    /// now-superseded answer overwrite the third's, even though both answer for A.
    @MainActor @Test func aStaleRequestGenerationIsDropped() async throws {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let accountA = Self.walletAccount(idByte: 42)
            let accountB = Self.walletAccount(idByte: 43)
            let staleBalance = Self.fullyOwnedBalance(Zatoshi(111))
            let freshBalance = Self.fullyOwnedBalance(Zatoshi(999))
            let gate = ResumableGate()
            let fetchCalls = SignalledRecords<Void>()

            var state = WalletBalances.State()
            state.$selectedWalletAccount.withLock { $0 = accountA }
            let store = TestStore(initialState: state) {
                WalletBalances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
                $0.sdkSynchronizer = .mocked(
                    latestState: { SynchronizerState.zero },
                    getLocalAccountBalances: {
                        let ordinal = fetchCalls.recordCall()
                        if ordinal == 1 {
                            await gate.wait()
                            return [accountA.id: staleBalance]
                        }
                        return [accountA.id: freshBalance]
                    }
                )
            }
            store.exhaustivity = .off

            // Request #1 for A parks on the gate.
            let firstRead = await store.send(.updateBalances)
            await fetchCalls.countReached(1)

            // Request #2, for B: resolves immediately, answers nothing (no entry for B).
            store.state.$selectedWalletAccount.withLock { $0 = accountB }
            await store.send(.updateBalances).finish()

            // Request #3, back on A: resolves immediately with the fresh figure.
            store.state.$selectedWalletAccount.withLock { $0 = accountA }
            let thirdRead = await store.send(.updateBalances)
            await store.receive(\.balanceUpdated)
            await thirdRead.finish()

            #expect(store.state.shieldedBalance == freshBalance.shieldedSpendableValue)

            // Release request #1's now-stale answer.
            gate.open()
            await store.receive(\.balanceUpdated)
            await firstRead.finish()

            #expect(
                store.state.shieldedBalance == freshBalance.shieldedSpendableValue,
                "a superseded request's answer must never overwrite a newer request's own result"
            )
        }
    }

    // MARK: - (4) An account switch re-derives spendability from its own dispatch, not the next tick

    /// A is syncing and has a concrete, fully-spendable balance. Switching to B and immediately
    /// dispatching a fresh read must stop `spendability` from answering for A before that read has
    /// any chance to land -- not wait for whatever synchronizer tick happens to come next.
    @MainActor @Test func selectionChangeRederivesSpendabilityBeforeAnyTick() async throws {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let accountA = Self.walletAccount(idByte: 44)
            let accountB = Self.walletAccount(idByte: 45)
            let balanceA = Self.fullyOwnedBalance(Zatoshi(500))

            var syncing = SynchronizerState.zero
            syncing.syncStatus = .syncing(0.5, false)

            var state = WalletBalances.State()
            state.$selectedWalletAccount.withLock { $0 = accountA }
            let store = TestStore(initialState: state) {
                WalletBalances()
            } withDependencies: {
                $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
                $0.sdkSynchronizer = .mocked(
                    latestState: { SynchronizerState.zero },
                    getLocalAccountBalances: { [accountA.id: balanceA] }
                )
            }
            store.exhaustivity = .off

            await store.send(.synchronizerStateChanged(syncing.redacted))
            let firstUpdate = await store.send(.updateBalances)
            await store.receive(\.balanceUpdated)
            await firstUpdate.finish()
            #expect(store.state.hasConcreteBalance)
            #expect(store.state.spendability == .everything)

            // Switch to B -- nothing has been published for it yet, and the sync is still
            // running, so the switch alone makes B's answer unresolved.
            store.state.$selectedWalletAccount.withLock { $0 = accountB }

            let request = await store.send(.updateBalances)
            #expect(
                store.state.spendability == .nothing,
                "must not go on answering with A's spendability while B's own request is still in flight"
            )
            await request.finish()
        }
    }
}
