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
//  Also covers `Root.State.isTerminalStallRebuildInFlight`: a benchmark dispatched by an earlier
//  `.refreshAutomaticServer` (attempt 2, before the give-up) can still be running when a later
//  give-up starts the rebuild. The terminal branch cancels that benchmark's own effect
//  (`automaticServerRefreshCancelId`), which is normally enough on its own -- TCA's `Send` already
//  refuses to deliver an action once its effect's Task is cancelled (`Effect.swift`'s
//  `Send.callAsFunction`) -- but leaves a residual window a genuine data race between two
//  concurrently-running effects could still hit (the cancellation flag and the delivery are not one
//  atomic step). `isTerminalStallRebuildInFlight` is the belt-and-suspenders for that window: the
//  test below drives it directly, by sending `.autoServerCandidateReady` while a rebuild is in
//  flight, rather than by racing a real cancelled effect -- a deterministically SEQUENCED test can
//  never observe that race (the cancel always happens-before the delivery attempt, so `Send` always
//  wins), only a genuinely concurrent one could, and that is not this framework's job to reproduce.
//  Placed here rather than in `RootAutoServerIdleGateTests.swift` since it is a property of the
//  REBUILD's own in-flight window, the same thing every other test in this file drives.
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
            // MOB-1853: `markSyncStalledTerminally`/`clearSyncStalledTerminally` now forward into
            // the SmartBanner's own reducer (`.home(.smartBanner(.syncStalledTerminally))`), whose
            // `.openBannerRequest` schedules a delayed `.openBanner` through `mainQueue` -- without
            // this override that hits the library's default `.unimplemented` test scheduler.
            $0.mainQueue = .immediate
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

    /// `latestBlockHeight` stays at `SynchronizerState.zero`'s default (0), same precedent as
    /// `RootAutoServerIdleGateTests.swift`'s identically-named fixture -- the Ironwood announcement
    /// check inside `.synchronizerStateChanged` short-circuits on `tip > 0` before it would
    /// otherwise need `zcashSDKEnvironment.ironwoodActivationHeight` stubbed.
    private func fixtureSyncState(_ status: SyncStatus) -> RedactableSynchronizerState {
        var syncState = SynchronizerState.zero
        syncState.syncStatus = status
        return syncState.redacted
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

            // A third give-up in the SAME foreground: budget exhausted, no further rebuild call --
            // MOB-1853: this now DOES raise the terminal-stalled flag and notify the SmartBanner
            // (covered on its own in `exhaustingTheRebuildBudgetRaisesTheTerminalStalledState`
            // below), so `store.finish()` has that short cascade to settle rather than nothing at
            // all.
            await store.send(.syncStalled(attempt: 1, gaveUp: true))
            await store.finish()
            #expect(rebuildCallCount.value == 2, "the budget is 2 rebuilds per foreground")
            #expect(store.state.terminalStallRebuildsThisForeground == 2)

            // Backgrounding resets the budget for the next foreground -- MOB-1853: and clears the
            // terminal-stalled flag just raised above, notifying the SmartBanner in turn; settle
            // that cascade too before the next send below.
            await store.send(.initialization(.appDelegate(.didEnterBackground)))
            await store.finish()
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

    // MARK: - MOB-1853: a rebuild cancelled at background cannot touch the next foreground

    /// A rebuild still waiting on the SDK/guard when the app backgrounds is cancelled by
    /// `.didEnterBackground`'s `.cancel(id: state.terminalStallRebuildCancelId)` -- but the mocked
    /// `rebuildAfterStall` below (like `RootRetryStartReentrancyTests`' `ResumableGate`-parked
    /// mocks) is not itself cancellation-aware, so its task stays suspended until the test
    /// releases it, exactly as if backgrounding landed mid-wait for real. TCA's `Send` refuses to
    /// deliver an action once its effect's task has been cancelled (`Effect.swift`'s
    /// `Send.callAsFunction`, see this file's header), so that stale completion -- whichever
    /// `oldResult` it would have carried -- must never reach the next foreground's fresh budget,
    /// terminal flag, or SmartBanner notification.
    @Test(arguments: [true, false])
    func aRebuildCancelledAtBackgroundCannotTouchTheNextForegroundsBudgetOrBanner(oldResult: Bool) async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let oldGate = ResumableGate()
            let callCount = LockIsolated(0)
            let store = makeStore(
                state: stalledState(),
                rebuildAfterStall: {
                    let ordinal = callCount.withValue { count -> Int in
                        count += 1
                        return count
                    }
                    guard ordinal == 1 else { return true }
                    // The rebuild this test cancels -- parks until the test releases it below.
                    await oldGate.wait()
                    return oldResult
                }
            )

            // Foreground 1: a give-up starts a rebuild that parks mid-flight, the same shape as a
            // real rebuild still waiting on the SDK/guard when backgrounding lands.
            await store.send(.syncStalled(attempt: 1, gaveUp: true)) {
                $0.isSyncStalledSinceLastProgress = true
                $0.terminalStallRebuildsThisForeground = 1
            }

            // Background while that rebuild is still in flight -- cancels its effect and resets
            // the per-foreground budget/flag, same as `RootAutoServerIdleGateTests`' backgrounding
            // coverage. Deliberately not `store.finish()` here: the parked rebuild above is not
            // itself cancellation-aware, so it would still read as "in flight" until `oldGate`
            // opens below -- exactly the still-unfinished-pipeline shape
            // `RootRetryStartReentrancyTests` drives the same way.
            await store.send(.initialization(.appDelegate(.didEnterBackground)))
            #expect(store.state.terminalStallRebuildsThisForeground == 0)
            #expect(store.state.isTerminalStallRebuildInFlight == false)

            // Foreground 2: a fresh give-up starts a second rebuild against the fresh budget,
            // which completes normally (this is the ordinal-2 call above).
            await store.send(.syncStalled(attempt: 1, gaveUp: true)) {
                $0.isSyncStalledSinceLastProgress = true
                $0.terminalStallRebuildsThisForeground = 1
            }
            await store.receive(\.terminalStallRebuildFinished) {
                $0.isTerminalStallRebuildInFlight = false
            }

            // Release the OLD, cancelled rebuild's parked continuation. Its own
            // `send(.terminalStallRebuildFinished(oldResult))` must be dropped by TCA -- the task
            // backing it was already cancelled at backgrounding above -- so the drain below can
            // safely wait for it to actually run to completion without ever delivering anything,
            // regardless of `oldResult`.
            //
            // Two `store.finish()` calls, both scoped to `.on` exhaustivity (rather than this
            // suite's usual `.off`, set in `makeStore` above): `TestStore.finish()` only checks
            // for an unhandled received action ONCE, in its very first line, before it waits for
            // in-flight effects to settle -- an action that arrives DURING that wait (exactly what
            // a wrongly-delivered stale completion released by `oldGate.open()` above would do) is
            // never re-checked afterwards by that same call. The first `finish()` call's wait is
            // what lets that stale delivery actually land (if production is broken); the second
            // call's own first line then sees it still sitting unhandled and fails via TCA's own
            // unexpected-action detection, regardless of its payload. `.on` (rather than `.off`)
            // is what turns that detection into a real failure instead of a silently skipped one --
            // under `.off`, `TestStore.state` simply never advances past an unconsumed received
            // action, so an `oldResult == true` delivery would go completely unnoticed: `started
            // == true` routes to `clearSyncStalledTerminally`, which no-ops because the flag is
            // already false, so neither `#expect` below would move either way. (Confirmed both
            // halves of this empirically: a single `withExhaustivity(.on) { await store.finish() }`
            // call does NOT catch a stale delivery injected by temporarily dropping
            // `startTerminalRebuild`'s `.cancellable(...)`; two calls do.)
            oldGate.open()
            await store.withExhaustivity(.on) {
                await store.finish()
                await store.finish()
            }

            #expect(
                store.state.terminalStallRebuildsThisForeground == 1,
                "a dropped completion from the backgrounded rebuild must not touch the next foreground's budget"
            )
            #expect(
                store.state.isSyncStalledTerminally == false,
                "a dropped completion must not raise the terminal flag regardless of what the cancelled rebuild would have returned"
            )
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

    // MARK: - A candidate arriving while a terminal rebuild is in flight must not apply

    /// Regression: attempt 2 (no give-up yet) dispatches `.refreshAutomaticServer`, whose benchmark
    /// can still be running when attempt 3 gives up and starts the terminal rebuild. The terminal
    /// branch cancels that benchmark's own effect, which TCA's `Send` normally makes airtight on its
    /// own -- but only against a happens-before-ordered cancel, never against a genuine data race
    /// between two concurrently-running effects (see the file header). `isTerminalStallRebuildInFlight`
    /// is the belt-and-suspenders for that residual window, so this test drives the arrival directly
    /// -- `.autoServerCandidateReady` while the rebuild is still in flight -- rather than via a real
    /// cancelled effect, which a deterministic test could never make land anyway. The handler must
    /// drop it, not stash it: `rebuildAfterStall` computes its own fresh candidate independently, so a
    /// stashed one would only replay a stale answer once the window closes.
    @Test
    func candidateArrivingWhileATerminalRebuildIsInFlightIsDroppedNotApplied() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let rebuildGate = ResumableGate()
            let applyCallCount = LockIsolated(0)
            let rebuildCallCount = LockIsolated(0)
            let store = makeStore(
                state: stalledState(),
                applySwitch: { _ in
                    applyCallCount.withValue { $0 += 1 }
                    return true
                },
                rebuildAfterStall: {
                    // Parked on a gate so this test controls exactly when the rebuild's own in-flight
                    // window closes.
                    await rebuildGate.wait()
                    rebuildCallCount.withValue { $0 += 1 }
                    return true
                }
            )

            await store.send(.syncStalled(attempt: 3, gaveUp: true)) {
                $0.isSyncStalledSinceLastProgress = true
                $0.terminalStallRebuildsThisForeground = 1
                $0.isTerminalStallRebuildInFlight = true
            }

            // A candidate arrives -- e.g. the stale benchmark from the scenario above -- while the
            // rebuild still owns the window.
            let candidate = endpoint("na.zec.rocks")
            await store.send(.autoServerCandidateReady(candidate, Date(timeIntervalSince1970: 1_000_000)))

            #expect(applyCallCount.value == 0, "a candidate arriving while a terminal rebuild is in flight must never apply")
            #expect(store.state.pendingServerCandidate == nil, "dropped, not stashed -- rebuildAfterStall computes its own fresh candidate")

            rebuildGate.open()
            await store.receive(\.terminalStallRebuildFinished) {
                $0.isTerminalStallRebuildInFlight = false
            }
            await store.finish()

            #expect(rebuildCallCount.value == 1)
        }
    }

    // MARK: - Once the rebuild's own window closes, a fresh candidate applies normally again

    /// The gate `isTerminalStallRebuildInFlight` closes is scoped to the rebuild's own in-flight
    /// window -- once `.terminalStallRebuildFinished` clears it, a candidate arriving afterward must
    /// be treated exactly like any other, not left permanently shut by a rebuild that has long since
    /// finished.
    @Test
    func freshCandidateAppliesNormallyOnceTheRebuildHasFinished() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let applyCallCount = LockIsolated(0)
            let store = makeStore(
                state: stalledState(),
                applySwitch: { _ in
                    applyCallCount.withValue { $0 += 1 }
                    return true
                },
                rebuildAfterStall: { true }
            )

            await store.send(.syncStalled(attempt: 3, gaveUp: true)) {
                $0.isSyncStalledSinceLastProgress = true
                $0.terminalStallRebuildsThisForeground = 1
                $0.isTerminalStallRebuildInFlight = true
            }
            await store.receive(\.terminalStallRebuildFinished) {
                $0.isTerminalStallRebuildInFlight = false
            }

            let candidate = endpoint("na.zec.rocks")
            await store.send(.autoServerCandidateReady(candidate, Date(timeIntervalSince1970: 1_000_000)))
            await store.finish()

            #expect(applyCallCount.value == 1, "the gate must reopen once the rebuild that closed it has finished")
            #expect(store.state.pendingServerCandidate == nil)
        }
    }

    // MARK: - MOB-1853: an exhausted budget raises the app's own honest terminal state

    /// Once the per-foreground rebuild budget is spent, the give-up that finds it exhausted must
    /// raise `isSyncStalledTerminally` and notify the SmartBanner -- the SDK's own error state used
    /// to be left on screen with nothing more said about it; now the banner can show it and offer
    /// Retry.
    @Test
    func exhaustingTheRebuildBudgetRaisesTheTerminalStalledState() async {
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

            // Rebuild #1 and #2 spend the whole per-foreground budget -- both start a pass, so
            // neither one raises the terminal flag.
            await store.send(.syncStalled(attempt: 1, gaveUp: true)) {
                $0.isSyncStalledSinceLastProgress = true
                $0.terminalStallRebuildsThisForeground = 1
            }
            await store.receive(\.terminalStallRebuildFinished)
            await store.send(.syncStalled(attempt: 1, gaveUp: true)) {
                $0.terminalStallRebuildsThisForeground = 2
            }
            await store.receive(\.terminalStallRebuildFinished)

            // A third give-up: budget exhausted -- the terminal-stalled flag rises and the
            // SmartBanner is told, since automatic recovery has nothing left to try this foreground.
            await store.send(.syncStalled(attempt: 1, gaveUp: true)) {
                $0.isSyncStalledTerminally = true
            }
            await store.receive(\.home.smartBanner.syncStalledTerminally) { _ in }   // true
            await store.finish()

            #expect(rebuildCallCount.value == 2)
            #expect(store.state.isSyncStalledTerminally == true)
        }
    }

    // MARK: - MOB-1853: a rebuild that starts nothing is exactly as terminal as a spent budget

    /// `rebuildAfterStall` returning `false` means the pass never actually started -- the wallet is
    /// left exactly as stuck as an exhausted budget would leave it, so `.terminalStallRebuildFinished`
    /// must raise the same honest terminal state on its very first give-up, budget or no budget.
    @Test
    func aRebuildThatStartsNothingRaisesTheTerminalStalledState() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(
                state: stalledState(),
                rebuildAfterStall: { false }
            )

            await store.send(.syncStalled(attempt: 1, gaveUp: true)) {
                $0.isSyncStalledSinceLastProgress = true
                $0.terminalStallRebuildsThisForeground = 1
            }
            await store.receive(\.terminalStallRebuildFinished) {
                $0.isSyncStalledTerminally = true
            }
            await store.receive(\.home.smartBanner.syncStalledTerminally) { _ in }   // true
            await store.finish()

            #expect(store.state.isSyncStalledTerminally == true)
        }
    }

    // MARK: - MOB-1853: a give-up while the latest known status is an error still notifies the banner

    /// The SmartBanner's stalled lane now outranks a persistent sync error (rank 0.75 vs 1) so its
    /// Retry stays reachable -- which makes it matter that Root's own give-up notification keeps
    /// firing unconditionally, whatever `lastKnownSyncStatus` currently reads. Same shape as
    /// `aRebuildThatStartsNothingRaisesTheTerminalStalledState` above, just with an `.error` snapshot
    /// recorded first.
    @Test
    func aFailedRebuildWhileTheLatestStateIsAnErrorNotifiesTheBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(
                state: stalledState(),
                rebuildAfterStall: { false }
            )

            await store.send(.synchronizerStateChanged(fixtureSyncState(.error(ZcashError.compactBlockProcessorCritical))))
            await store.finish()
            #expect(store.state.lastKnownSyncStatus == .error(ZcashError.compactBlockProcessorCritical), "the fixture must actually exercise an error status this is testing against")

            await store.send(.syncStalled(attempt: 1, gaveUp: true)) {
                $0.isSyncStalledSinceLastProgress = true
                $0.terminalStallRebuildsThisForeground = 1
            }
            await store.receive(\.terminalStallRebuildFinished) {
                $0.isSyncStalledTerminally = true
            }
            await store.receive({
                guard case .home(.smartBanner(.syncStalledTerminally(let isStalled, let retriedByUser))) = $0 else { return false }
                return isStalled == true && retriedByUser == false
            })
            await store.finish()

            #expect(store.state.isSyncStalledTerminally == true)
        }
    }

    // MARK: - MOB-1853: the engine visibly recovering retires the terminal state

    /// The same progress-clear edge that retires `isSyncStalledSinceLastProgress`
    /// (`RootAutoServerIdleGateTests.swift` covers that flag on its own) must retire the terminal
    /// state too, and tell the SmartBanner so a stalled banner does not survive a sync that has
    /// actually recovered.
    @Test
    func progressClearsTheTerminalStalledState() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = stalledState()
            state.lastKnownSyncProgress = 0.3
            state.isSyncStalledSinceLastProgress = true
            state.isSyncStalledTerminally = true
            let store = makeStore(state: state)

            await store.send(.synchronizerStateChanged(fixtureSyncState(.syncing(0.4, false)))) {
                $0.isSyncStalledSinceLastProgress = false
                $0.lastKnownSyncProgress = 0.4
                $0.isSyncStalledTerminally = false
            }
            await store.receive(\.home.smartBanner.syncStalledTerminally) { _ in }   // false
            await store.finish()

            // `Root.State` isn't `Equatable`, so the `send` closure above documents intent but
            // cannot itself catch a wrong value -- this is the assertion that actually does.
            #expect(store.state.isSyncStalledTerminally == false)
        }
    }

    // MARK: - MOB-1853: Retry resets the budget and re-enters the rebuild path once

    /// The stalled banner's Retry action (`.home(.smartBanner(.retryStalledSyncTapped))`, forwarded
    /// by `RootCoordinator.swift` into `.retryTerminalStallRebuild`) gives the wallet exactly one
    /// more attempt: a fresh budget, one rebuild dispatched immediately, and the terminal flag
    /// cleared up front so the banner does not sit on a stale reading while that attempt runs.
    @Test
    func retryResetsTheBudgetAndRebuildsOnce() async {
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

            // Spend the whole per-foreground budget, same as the exhaustion test above.
            await store.send(.syncStalled(attempt: 1, gaveUp: true)) {
                $0.isSyncStalledSinceLastProgress = true
                $0.terminalStallRebuildsThisForeground = 1
            }
            await store.receive(\.terminalStallRebuildFinished)
            await store.send(.syncStalled(attempt: 1, gaveUp: true)) {
                $0.terminalStallRebuildsThisForeground = 2
            }
            await store.receive(\.terminalStallRebuildFinished)
            await store.send(.syncStalled(attempt: 1, gaveUp: true)) {
                $0.isSyncStalledTerminally = true
            }
            await store.receive(\.home.smartBanner.syncStalledTerminally) { _ in }

            // Retry: resets the budget and re-enters the rebuild path exactly once -- rebuild #3
            // overall.
            await store.send(.home(.smartBanner(.retryStalledSyncTapped)))
            await store.receive(\.retryTerminalStallRebuild) {
                $0.terminalStallRebuildsThisForeground = 1
                $0.isSyncStalledTerminally = false
            }
            // MOB-1853: pins the optimistic-dismiss payload -- Retry must notify `false` with
            // `retriedByUser: true`, not the genuine-clear shape every other site sends, or the
            // SmartBanner would re-seat the (Retry-less) error banner while this fresh attempt is
            // still in flight.
            await store.receive({
                guard case .home(.smartBanner(.syncStalledTerminally(let isStalled, let retriedByUser))) = $0 else { return false }
                return isStalled == false && retriedByUser == true
            })
            await store.finish()

            #expect(rebuildCallCount.value == 3)
            #expect(store.state.terminalStallRebuildsThisForeground == 1)
            // `Root.State` isn't `Equatable`, so the `receive` closure above documents intent but
            // cannot itself catch a wrong value -- this is the assertion that actually does.
            #expect(store.state.isSyncStalledTerminally == false)
        }
    }

    // MARK: - A refused Retry leaves the stalled banner, its Retry button, and the budget untouched

    /// `startTerminalRebuild`'s own doc comment leaves the `bgTask`/server-setup guard to its
    /// callers -- the give-up path (`rebuildIsSkippedWhileServerSetupIsVisible` above) applies it,
    /// and Retry must too. Unlike the give-up path, Retry cannot perform its optimistic dismiss
    /// first and check the guard after: a refused Retry that already closed the banner would leave
    /// nothing to answer the tap -- no rebuild will run, so no `.terminalStallRebuildFinished` ever
    /// arrives, and the dismiss's `retriedByUser: true` deliberately keeps the error banner
    /// suppressed underneath. So the guard runs first, and when it refuses, the arm changes
    /// nothing: the stalled banner, its Retry button, and the per-foreground budget all stay
    /// exactly as they were.
    @Test
    func retryIsSkippedWhileServerSetupIsVisible() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = stalledState()
            state.serverSetupViewBinding = true
            state.isSyncStalledTerminally = true
            state.terminalStallRebuildsThisForeground = 2
            let rebuildCallCount = LockIsolated(0)
            let store = makeStore(
                state: state,
                rebuildAfterStall: {
                    rebuildCallCount.withValue { $0 += 1 }
                    return true
                }
            )

            await store.send(.retryTerminalStallRebuild)
            await store.withExhaustivity(.on) {
                await store.finish()
                await store.finish()
            }

            #expect(rebuildCallCount.value == 0, "Server Setup owns the synchronizer -- Retry must not tear it down from underneath it")
            #expect(store.state.terminalStallRebuildsThisForeground == 2)
            // `Root.State` isn't `Equatable`, and `send` above carries no mutation closure since
            // nothing should change -- these are the assertions that actually catch a wrong value.
            #expect(store.state.isSyncStalledTerminally == true)
        }
    }
}
