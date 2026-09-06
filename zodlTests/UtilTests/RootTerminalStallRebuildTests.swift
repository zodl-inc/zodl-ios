//
//  RootTerminalStallRebuildTests.swift
//  zodlTests
//
//  MOB-1853 — once the SDK's own stall recovery gives up (`.syncStalled(gaveUp: true)`), a
//  benchmark-only refresh (`.refreshAutomaticServer`) is not enough: manual mode has no candidate to
//  offer, and even Automatic mode's ordinary switch is a no-op when the winning candidate is the
//  server already configured. `RootTransactions.swift`'s `.syncStalled` handler instead calls
//  `autoServerSelection.rebuildAfterStall()` — which always restarts at SOMETHING, the current
//  endpoint included — at most `Root.State.maxTerminalStallRebuildsPerForeground` (2) times per
//  foreground, so a wallet that cannot be revived this way settles on the SDK's own visible error
//  state instead of retrying forever. See `AutoServerSelectionRebuildTests.swift` for the dependency
//  itself; this file covers only the bounding/wiring done in `Root`.
//
//  Mirrors `RootAutoServerIdleGateTests.swift`'s fixtures and `makeStore` shape (that file keeps the
//  still-unchanged benchmark-only path for `attempt >= 2, gaveUp: false`, plus a regression proving
//  `rebuildAfterStall` stays untouched by it).
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RootTerminalStallRebuildTests {
    // MARK: - Fixtures

    /// Builds a `Root` `TestStore` seeded with a mid-sync status (so the stall-hook guards below it
    /// are the only ones under test) and spy-free no-op dependencies unless overridden.
    private func makeStore(
        state: Root.State,
        applySwitch: @escaping @Sendable (LightWalletEndpoint) async -> Bool = { _ in false },
        rebuildAfterStall: @escaping @Sendable () async -> Bool = { false }
    ) -> TestStore<Root.State, Root.Action> {
        let store = TestStore(initialState: state) {
            Root()
        } withDependencies: {
            $0.autoServerSelection = AutoServerSelectionClient(
                findBestServer: { nil },
                applySwitch: applySwitch,
                rebuildAfterStall: rebuildAfterStall
            )
            $0.sdkSynchronizer = .mocked()
            $0.date.now = { Date(timeIntervalSince1970: 1_000_000) }
        }
        store.exhaustivity = .off
        return store
    }

    private func stalledState() -> Root.State {
        var state = Root.State.initial
        state.lastKnownSyncStatus = .syncing(0.5, false)
        return state
    }

    private func endpoint(_ host: String) -> LightWalletEndpoint {
        LightWalletEndpoint(address: host, port: 443, secure: true, streamingCallTimeoutInMillis: 0)
    }

    // MARK: - A single give-up runs exactly one bounded rebuild through the dependency

    @Test
    func giveUpTriggersOneBoundedRebuildThroughTheDependency() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let rebuildCallCount = LockIsolated(0)
            let store = makeStore(
                state: stalledState(),
                rebuildAfterStall: {
                    rebuildCallCount.withValue { $0 += 1 }
                    return true
                }
            )

            await store.send(.syncStalled(attempt: 3, gaveUp: true)) {
                $0.isSyncStalledSinceLastProgress = true
                $0.terminalStallRebuildsThisForeground = 1
            }
            await store.receive(\.terminalStallRebuildFinished)
            await store.finish()

            #expect(rebuildCallCount.value == 1)
            #expect(store.state.terminalStallRebuildsThisForeground == 1)
        }
    }

    // MARK: - The budget is 2 rebuilds per foreground, and backgrounding resets it

    @Test
    func rebuildsAreBoundedPerForegroundAndResetOnBackground() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let rebuildCallCount = LockIsolated(0)
            let store = makeStore(
                state: stalledState(),
                rebuildAfterStall: {
                    rebuildCallCount.withValue { $0 += 1 }
                    return true
                }
            )

            // Rebuild #1.
            await store.send(.syncStalled(attempt: 1, gaveUp: true)) {
                $0.isSyncStalledSinceLastProgress = true
                $0.terminalStallRebuildsThisForeground = 1
            }
            await store.receive(\.terminalStallRebuildFinished)
            #expect(rebuildCallCount.value == 1)

            // Rebuild #2 -- reaches the per-foreground cap.
            await store.send(.syncStalled(attempt: 1, gaveUp: true)) {
                $0.terminalStallRebuildsThisForeground = 2
            }
            await store.receive(\.terminalStallRebuildFinished)
            #expect(rebuildCallCount.value == 2)

            // A third give-up in the SAME foreground: budget exhausted, no further call and no
            // effect dispatched at all -- `store.finish()` would hang on a stray one.
            await store.send(.syncStalled(attempt: 1, gaveUp: true))
            await store.finish()
            #expect(rebuildCallCount.value == 2, "the budget is 2 rebuilds per foreground")
            #expect(store.state.terminalStallRebuildsThisForeground == 2)

            // Backgrounding resets the budget for the next foreground.
            await store.send(.initialization(.appDelegate(.didEnterBackground)))
            #expect(store.state.terminalStallRebuildsThisForeground == 0)

            // A give-up in the new foreground is allowed again -- rebuild #3 overall.
            await store.send(.syncStalled(attempt: 1, gaveUp: true)) {
                $0.isSyncStalledSinceLastProgress = true
                $0.terminalStallRebuildsThisForeground = 1
            }
            await store.receive(\.terminalStallRebuildFinished)
            await store.finish()

            #expect(rebuildCallCount.value == 3)
        }
    }

    // MARK: - A rebuild must never tear down the synchronizer while Server Setup owns it

    @Test
    func rebuildIsSkippedWhileServerSetupIsVisible() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = stalledState()
            state.serverSetupViewBinding = true
            let rebuildCallCount = LockIsolated(0)
            let store = makeStore(
                state: state,
                rebuildAfterStall: {
                    rebuildCallCount.withValue { $0 += 1 }
                    return true
                }
            )

            await store.send(.syncStalled(attempt: 1, gaveUp: true)) {
                $0.isSyncStalledSinceLastProgress = true
            }
            await store.finish()

            #expect(rebuildCallCount.value == 0)
            #expect(store.state.terminalStallRebuildsThisForeground == 0)
        }
    }

    // MARK: - A candidate parked before the give-up is stale and must not replay through applySwitch

    @Test
    func giveUpClearsAPendingCandidateSoItNeverReplaysThroughApplySwitch() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = stalledState()
            // Closes `canApplyAutoServerSwitch` via `isSensitiveFlowActive` without touching
            // `bgTask`/`isServerSetupVisible` -- the give-up handler's own guard only checks those
            // two, so the rebuild below still runs while the deferred-candidate gate stays shut.
            state.signWithKeystoneCoordFlowBinding = true
            state.pendingServerCandidate = Root.State.PendingServerCandidate(
                endpoint: endpoint("na.zec.rocks"),
                benchmarkedAt: Date(timeIntervalSince1970: 1_000_000)
            )

            let applyCallCount = LockIsolated(0)
            let store = makeStore(
                state: state,
                applySwitch: { _ in
                    applyCallCount.withValue { $0 += 1 }
                    return true
                },
                rebuildAfterStall: { true }
            )

            await store.send(.syncStalled(attempt: 3, gaveUp: true)) {
                $0.isSyncStalledSinceLastProgress = true
                $0.terminalStallRebuildsThisForeground = 1
                $0.pendingServerCandidate = nil
            }
            await store.receive(\.terminalStallRebuildFinished)

            // Open the gate: the sensitive flow ends.
            await store.send(.binding(.set(\.signWithKeystoneCoordFlowBinding, false)))
            await store.finish()

            #expect(applyCallCount.value == 0, "a candidate parked before the give-up is stale -- rebuildAfterStall already computed a fresh one")
            #expect(store.state.pendingServerCandidate == nil)
        }
    }
}
