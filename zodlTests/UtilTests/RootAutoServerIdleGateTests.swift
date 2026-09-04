//
//  RootAutoServerIdleGateTests.swift
//  zodlTests
//
//  MOB-1853 — automatic server switches must not race an active sync. Covers
//  `Root.State.isSynchronizerIdleForSwitch` / `canApplyAutoServerSwitch` picking up
//  `lastKnownSyncStatus` (`RootStore.swift`), `.synchronizerStateChanged` recording it and
//  clearing a recorded stall (`RootInitialization.swift`), `.didEnterBackground` cancelling an
//  in-flight refresh and resetting both to their "unknown" state (`RootInitialization.swift`),
//  and the `.syncStalled` stall hook that only unblocks a switch from the SDK's second recovery
//  restart onward, or once it gives up outright (`RootTransactions.swift`).
//
//  Mirrors `RootAutoServerCandidateTests` (`AutoServerSelectionClientTests.swift`) for driving
//  `Root` via `TestStore` with `exhaustivity = .off`, and `RootIronwoodAnnouncementGateTests`'
//  `fixtureSyncState` for building a `RedactableSynchronizerState` off `SynchronizerState.zero`.
//  `latestBlockHeight` is deliberately left at its `.zero` default throughout this file: the
//  Ironwood announcement check inside `.synchronizerStateChanged` short-circuits on `tip > 0`
//  before it would otherwise need `zcashSDKEnvironment.ironwoodActivationHeight` stubbed.
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized, and each test additionally scopes a fresh `InMemoryStorage()` via
// `withDependencies` — the same belt-and-suspenders precedent as `RootAutoServerCandidateTests`
// for a suite driving `Root.State`'s process-global `@Shared(.inMemory(...))` keys.
@Suite(.serialized) @MainActor struct RootAutoServerIdleGateTests {
    // MARK: - Fixtures

    private func endpoint(_ host: String) -> LightWalletEndpoint {
        LightWalletEndpoint(address: host, port: 443, secure: true, streamingCallTimeoutInMillis: 0)
    }

    /// `latestBlockHeight` stays at `SynchronizerState.zero`'s default (0) -- see the file header
    /// for why that keeps the Ironwood announcement check a no-op.
    private func fixtureSyncState(_ status: SyncStatus) -> RedactableSynchronizerState {
        var syncState = SynchronizerState.zero
        syncState.syncStatus = status
        return syncState.redacted
    }

    /// Builds a `Root` `TestStore`. `autoServerSelection` defaults to spy-free no-ops; individual
    /// tests override `findBestServer`/`applySwitch` to observe what the gate actually did.
    private func makeStore(
        state: Root.State,
        findBestServer: @escaping @Sendable () async -> LightWalletEndpoint? = { nil },
        applySwitch: @escaping @Sendable (LightWalletEndpoint) async -> Bool = { _ in false }
    ) -> TestStore<Root.State, Root.Action> {
        let store = TestStore(initialState: state) {
            Root()
        } withDependencies: {
            $0.autoServerSelection = AutoServerSelectionClient(
                findBestServer: findBestServer,
                applySwitch: applySwitch
            )
            $0.sdkSynchronizer = .mocked()
            $0.date.now = { Date(timeIntervalSince1970: 1_000_000) }
        }
        store.exhaustivity = .off
        return store
    }

    // MARK: - 1 & 2: a candidate is parked while syncing, then applied once sync reaches upToDate

    @Test
    func candidateArrivesWhileSyncingIsParkedThenAppliedOnceUpToDate() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.lastKnownSyncStatus = .syncing(0.5, false)
            // Isolates this test from the migration-reconcile edge `.synchronizerStateChanged`
            // also runs on an `.upToDate` tick -- not what this test is about.
            state.wasSyncUpToDateForMigration = true

            let applyCallCount = LockIsolated(0)
            let store = makeStore(
                state: state,
                applySwitch: { _ in
                    applyCallCount.withValue { $0 += 1 }
                    return true
                }
            )

            let candidate = endpoint("na.zec.rocks")
            let benchmarkedAt = Date(timeIntervalSince1970: 1_000_000)

            // 1. A candidate arriving while syncing is parked, not applied: `.syncing` is not idle.
            await store.send(.autoServerCandidateReady(candidate, benchmarkedAt))
            #expect(store.state.pendingServerCandidate?.endpoint.host == candidate.host)
            #expect(applyCallCount.value == 0)

            // 2. Sync reaching `.upToDate` flips `canApplyAutoServerSwitch` true; `Root.body`'s
            // `onChange` re-feeds the parked candidate and it applies exactly once.
            await store.send(.synchronizerStateChanged(fixtureSyncState(.upToDate)))
            await store.finish()

            #expect(applyCallCount.value == 1)
            #expect(store.state.pendingServerCandidate == nil)
        }
    }

    // MARK: - 3: an unknown sync status keeps the gate closed

    @Test
    func nilSyncStatusClosesTheGate() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            // `Root.State.initial` leaves `lastKnownSyncStatus` at its `nil` default -- nothing
            // observed yet this session.
            let state = Root.State.initial
            let applyCallCount = LockIsolated(0)
            let store = makeStore(
                state: state,
                applySwitch: { _ in
                    applyCallCount.withValue { $0 += 1 }
                    return true
                }
            )

            let candidate = endpoint("na.zec.rocks")
            await store.send(.autoServerCandidateReady(candidate, Date(timeIntervalSince1970: 1_000_000)))

            #expect(store.state.pendingServerCandidate?.endpoint.host == candidate.host)
            #expect(applyCallCount.value == 0, "an unknown sync status must never read as idle")
        }
    }

    // MARK: - 4: backgrounding cancels a running refresh

    @Test
    func backgroundingCancelsTheRefreshEffect() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.lastKnownSyncStatus = .upToDate

            // Deliberately never resolves on its own (a real benchmark call could easily run
            // longer than a background transition) -- this proves the effect is CANCELLED by
            // `.didEnterBackground`, not merely outraced by a faster stub.
            let store = makeStore(
                state: state,
                findBestServer: {
                    try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
                    return nil
                }
            )

            await store.send(.refreshAutomaticServer)
            await store.send(.initialization(.appDelegate(.didEnterBackground)))

            // `TestStore.finish()` is bounded by its own 1s default timeout: if the cancel above
            // never reached `automaticServerRefreshCancelId`'s effect, this reports the
            // still-in-flight effect as a failure instead of hanging on the 60s stub.
            await store.finish()
        }
    }

    // MARK: - 5: the stall hook only unblocks a switch from the second restart, or a give-up

    @Test
    func firstAttemptStallIsLoggedOnlyAndLeavesTheGateClosed() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.lastKnownSyncStatus = .syncing(0.5, false)
            // `store.exhaustivity = .off` means `store.finish()` alone would silently accept an
            // unreceived `.refreshAutomaticServer` -- that proves nothing about whether the effect
            // actually ran. Wiring a spy into `findBestServer` (the first thing `.refreshAutomaticServer`
            // does) and asserting it was never invoked is what actually proves "no refresh happened".
            let findBestServerCallCount = LockIsolated(0)
            let store = makeStore(
                state: state,
                findBestServer: {
                    findBestServerCallCount.withValue { $0 += 1 }
                    return nil
                }
            )

            await store.send(.syncStalled(attempt: 1, gaveUp: false))
            await store.finish()

            #expect(!store.state.isSyncStalledSinceLastProgress, "attempt 1 is the SDK's own cheap reconnect and must get its chance first")
            #expect(findBestServerCallCount.value == 0, "attempt 1 must not trigger a refresh")
        }
    }

    @Test
    func secondAttemptStallOpensTheGateAndSendsARefresh() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.lastKnownSyncStatus = .syncing(0.5, false)
            let store = makeStore(state: state)

            await store.send(.syncStalled(attempt: 2, gaveUp: false)) {
                $0.isSyncStalledSinceLastProgress = true
            }
            await store.receive(\.refreshAutomaticServer)
            await store.finish()
        }
    }

    @Test
    func gaveUpStallOpensTheGateAndSendsARefresh() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.lastKnownSyncStatus = .syncing(0.5, false)
            let store = makeStore(state: state)

            // Same shape as attempt 2: a give-up unblocks the switch regardless of the attempt
            // count that reached it.
            await store.send(.syncStalled(attempt: 3, gaveUp: true)) {
                $0.isSyncStalledSinceLastProgress = true
            }
            await store.receive(\.refreshAutomaticServer)
            await store.finish()
        }
    }

    // MARK: - 6: `.synchronizerStateChanged` clears a recorded stall once the engine visibly
    // makes progress again (`RootInitialization.swift`'s `.upToDate`/`.syncing` handling)

    @Test
    func stalledFlagClearsOnUpToDate() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.lastKnownSyncStatus = .syncing(0.5, false)
            state.isSyncStalledSinceLastProgress = true
            // Isolates this test from the migration-reconcile edge `.synchronizerStateChanged`
            // also runs on an `.upToDate` tick -- not what this test is about (same precedent as
            // test 1&2's fixture above).
            state.wasSyncUpToDateForMigration = true
            let store = makeStore(state: state)

            await store.send(.synchronizerStateChanged(fixtureSyncState(.upToDate))) {
                $0.isSyncStalledSinceLastProgress = false
            }
            await store.finish()
        }
    }

    @Test
    func stalledFlagClearsWhenSyncingProgressAdvancesPastLastRecorded() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.lastKnownSyncStatus = .syncing(0.3, false)
            state.lastKnownSyncProgress = 0.3
            state.isSyncStalledSinceLastProgress = true
            let store = makeStore(state: state)

            await store.send(.synchronizerStateChanged(fixtureSyncState(.syncing(0.4, false)))) {
                $0.isSyncStalledSinceLastProgress = false
                $0.lastKnownSyncProgress = 0.4
            }
            await store.finish()
        }
    }

    @Test
    func stalledFlagStaysSetWhenSyncingProgressIsUnchanged() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.lastKnownSyncStatus = .syncing(0.4, false)
            state.lastKnownSyncProgress = 0.4
            state.isSyncStalledSinceLastProgress = true
            let store = makeStore(state: state)

            await store.send(.synchronizerStateChanged(fixtureSyncState(.syncing(0.4, false))))
            await store.finish()

            #expect(store.state.isSyncStalledSinceLastProgress, "equal progress is not forward movement")
            #expect(store.state.lastKnownSyncProgress == 0.4)
        }
    }

    @Test
    func firstSyncingTickRecordsProgressAndFlagClearsOnNextHigherTick() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.lastKnownSyncStatus = .syncing(0.2, false)
            state.lastKnownSyncProgress = nil
            state.isSyncStalledSinceLastProgress = true
            let store = makeStore(state: state)

            // First tick: nothing recorded yet to compare against, so the flag must NOT clear --
            // but the progress DOES get recorded, for the next tick to compare against.
            await store.send(.synchronizerStateChanged(fixtureSyncState(.syncing(0.2, false)))) {
                $0.lastKnownSyncProgress = 0.2
            }
            #expect(store.state.isSyncStalledSinceLastProgress, "nothing to compare against on the very first observed tick")

            // Second, higher tick: now clears against the just-recorded progress.
            await store.send(.synchronizerStateChanged(fixtureSyncState(.syncing(0.3, false)))) {
                $0.isSyncStalledSinceLastProgress = false
                $0.lastKnownSyncProgress = 0.3
            }
            await store.finish()
        }
    }
}
