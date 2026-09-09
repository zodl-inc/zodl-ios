//
//  SmartBannerSyncStalledTests.swift
//  zodlTests
//
//  MOB-1853 — once automatic stall recovery has given up for good this foreground (the
//  terminal-stall rebuild budget spent, a rebuild blocked by the `bgTask`/server-setup guard, or a
//  dispatched rebuild that never actually started a pass), `Root` notifies the SmartBanner via
//  `.syncStalledTerminally(Bool, retriedByUser: Bool)` (`RootTransactions.swift`'s
//  `markSyncStalledTerminally`/`clearSyncStalledTerminally`), and this lane (`.priorityStalled`,
//  rank 0.75 — directly below `.priority1` lost connection and above `.priority2` sync error) shows
//  an honest "Sync has stalled" banner with a Retry action instead of the SDK's own `.syncing`
//  publishing forever with nothing said about it, and keeps that Retry reachable even while a
//  persistent sync error is also showing. `retriedByUser` further distinguishes a user-initiated
//  Retry tap's optimistic dismiss from every other, genuine clear -- only the latter re-seats the
//  error banner. `RootTerminalStallRebuildTests.swift` covers the Root-side wiring that produces
//  the notification; this file covers only the banner lane itself.
//
//  Mirrors `SmartBannerResidualSlotTests.swift`/`SmartBannerShieldingOfferLifecycleTests.swift` for
//  driving `SmartBanner` via `TestStore` with `exhaustivity = .off`, `mainQueue = .immediate`, and
//  an isolated `InMemoryStorage()` per test (`SmartBanner.State` carries `@Shared(.inMemory(...))`
//  process-global storage).
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SmartBannerSyncStalledTests {
    private static func syncState(
        _ status: SyncStatus,
        latestBlockHeight: BlockHeight = .zero
    ) -> RedactableSynchronizerState {
        var state = SynchronizerState.zero
        state.syncStatus = status
        state.latestBlockHeight = latestBlockHeight
        return state.redacted
    }

    private func makeStore(
        priorityContent: SmartBanner.State.PriorityContent? = nil,
        isSyncStalledTerminally: Bool = false,
        lastKnownErrorMessage: String = ""
    ) -> TestStore<SmartBanner.State, SmartBanner.Action> {
        var state = SmartBanner.State()
        state.priorityContent = priorityContent
        state.isSyncStalledTerminally = isSyncStalledTerminally
        state.lastKnownErrorMessage = lastKnownErrorMessage

        let store = TestStore(initialState: state) {
            SmartBanner()
        }
        store.exhaustivity = .off
        store.dependencies.mainQueue = .immediate
        store.dependencies.walletStorage = .noOp
        store.dependencies.sdkSynchronizer = .noOp
        return store
    }

    /// The lane seats over an ordinary syncing snapshot (rank 0.75 outranks priority4's rank 3.0,
    /// so the ladder's own `isSyncingHigherPriority` re-trigger can never displace it), and closes
    /// the moment Root reports the stall cleared.
    @Test func theStalledBannerShowsOverASyncingSnapshotAndClosesWhenCleared() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()

            await store.send(.syncStalledTerminally(true, retriedByUser: false)) {
                $0.isSyncStalledTerminally = true
            }
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)

            #expect(store.state.priorityContent == .priorityStalled)

            // Seeded WELL above `Constants.smartBannerSyncingBlocksThreshold` (3456) so priority4's
            // own re-trigger genuinely fires and competes for the slot — a snapshot left at
            // `SynchronizerState.zero`'s default (0 remaining blocks) would never even ask, which
            // would make the assertion below vacuous. `priorityContentRequested` landing on
            // `.priority4` is the proof the request was actually made; `priorityContent` staying on
            // `.priorityStalled` is the proof rank 0.75 still beat rank 3.0 and the request lost.
            await store.send(.synchronizerStateChanged(Self.syncState(.syncing(0.1, false), latestBlockHeight: 4_200_000)))
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContentRequested == .priority4, "the syncing snapshot must genuinely ask for priority4, not silently skip because blocks-remaining stayed under threshold")
            #expect(store.state.priorityContent == .priorityStalled, "an ordinary syncing tick must not displace the stronger stalled banner")

            await store.send(.syncStalledTerminally(false, retriedByUser: false)) {
                $0.isSyncStalledTerminally = false
            }
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == nil, "clearing the flag while the lane is seated must close the banner")
        }
    }

    /// `.retryStalledSyncTapped` is a pure delegate — `Root` is the one that reacts to it
    /// (re-entering the rebuild path and, once it clears the flag, sending
    /// `.syncStalledTerminally(false, retriedByUser: true)` back down); this reducer's own handler
    /// changes nothing.
    @Test func retryTapIsForwardedToTheParent() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(priorityContent: .priorityStalled, isSyncStalledTerminally: true)

            await store.send(.retryStalledSyncTapped)
            await store.finish()

            #expect(store.state.priorityContent == .priorityStalled)
            #expect(store.state.isSyncStalledTerminally)
        }
    }

    /// MOB-1853: `priorityStalled` (rank 0.75) now outranks `priority2` (sync error, rank 1), so a
    /// sync error can no longer displace an already-terminal stalled banner (see
    /// `aTerminalStallFollowedByAPersistentSyncErrorKeepsTheStalledBanner` below) -- which means
    /// `priority2` seated while `isSyncStalledTerminally` is already true is no longer reachable
    /// through the normal action sequence: `.syncStalledTerminally(true)` now displaces `.priority2`
    /// the instant the flag flips, rather than leaving it seated until a later tick re-walks into
    /// `.priorityStalled`. This fixture seeds that combination directly so the re-walk mechanism
    /// itself -- `syncStatusChangedEffect`'s `isSyncing` branch closing and re-evaluating rather than
    /// just leaving the ladder wherever a plain close would land it -- stays covered defensively.
    @Test func aTransientSyncErrorReRaisesTheStalledBannerOnceItClears() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(priorityContent: .priority2, isSyncStalledTerminally: true)
            #expect(store.state.priorityContent == .priority2)

            // The error clears, but the wallet is still stuck -- the stalled banner must come back
            // rather than leaving a bare spinner behind.
            await store.send(.synchronizerStateChanged(Self.syncState(.syncing(0.1, false))))
            await store.finish()
            await store.skipReceivedActions(strict: false)
            #expect(store.state.priorityContent == .priorityStalled, "clearing a transient error must re-raise the still-terminal stalled banner, not leave the banner closed")
        }
    }

    /// The negative of the test above: if Root's flag clears WHILE the transient error is showing
    /// (the rebuild that caused the error dispatched in the meantime actually started a pass), the
    /// re-walk triggered once the error itself clears must continue past `.priorityStalled` rather
    /// than reseat it — `.evaluatePriorityStalled`'s own guard on `state.isSyncStalledTerminally`
    /// is what makes that call, same as every other entry into that rung. Seeded the same way as
    /// the test above, for the same MOB-1853 reason (see its doc comment).
    @Test func theLadderContinuesPastStalledWhenTheFlagClearedWhileAnErrorWasShowing() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(priorityContent: .priority2, isSyncStalledTerminally: true)
            #expect(store.state.priorityContent == .priority2)

            // The flag clears while the error banner is still up -- `.priorityContent` is
            // `.priority2`, not `.priorityStalled`, so this only retracts THIS lane's own seat
            // (there isn't one to retract) and leaves the error banner exactly where it was.
            await store.send(.syncStalledTerminally(false, retriedByUser: false)) {
                $0.isSyncStalledTerminally = false
            }
            await store.finish()
            #expect(store.state.priorityContent == .priority2, "clearing the flag must not touch a DIFFERENT lane's seat")

            // The error clears -- the ladder re-walks through `.evaluatePriorityStalled`, finds the
            // flag false, and must continue past it rather than reseating a stall that is over.
            await store.send(.synchronizerStateChanged(Self.syncState(.syncing(0.1, false))))
            await store.finish()
            await store.skipReceivedActions(strict: false)
            #expect(store.state.priorityContent != .priorityStalled, "the ladder must continue past stalled once the flag is no longer set")
        }
    }

    /// MOB-1853: `isSyncTimedOut` latches on `lastKnownErrorMessage`, which is never
    /// cleared for the session — checking it before the priority-specific sheets would send a
    /// wallet that saw a 504 earlier and has since stalled to the stale timed-out sheet instead of
    /// the stalled help it actually needs.
    @Test func tappingTheStalledBannerOpensTheStalledHelpEvenAfterAnEarlierTimeout() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(
                priorityContent: .priorityStalled,
                isSyncStalledTerminally: true,
                lastKnownErrorMessage: "504 gateway timeout"
            )
            #expect(store.state.isSyncTimedOut, "the fixture must actually exercise the timed-out latch this is testing against")

            await store.send(.smartBannerContentTapped)

            #expect(store.state.isSmartBannerSheetPresented, "must open the generic, priority-driven sheet so `.priorityStalled` routes to the stalled help content")
            #expect(store.state.isSyncTimedOutSheetPresented == false, "must NOT fall into the stale timed-out sheet")
        }
    }

    /// MOB-1853: the stalled lane's rank moved above `priority2` (0.75 vs 1) specifically so a
    /// persistent sync error can no longer strand the stalled banner's own Retry action once
    /// automatic recovery has given up -- a sync error is diagnosable and often self-resolving, but
    /// a terminal stall that already exhausted its own recovery is neither, and the SDK's own
    /// `.error` publishing never stops on its own to let a later `.syncing` tick re-walk the ladder.
    @Test func aPersistentSyncErrorFollowedByATerminalStallShowsTheStalledBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()

            await store.send(.synchronizerStateChanged(Self.syncState(.error(ZcashError.compactBlockProcessorCritical))))
            await store.finish()
            await store.skipReceivedActions(strict: false)
            #expect(store.state.priorityContent == .priority2, "the error snapshot must seat the sync-error banner first")

            await store.send(.syncStalledTerminally(true, retriedByUser: false)) {
                $0.isSyncStalledTerminally = true
            }
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == .priorityStalled, "the stalled banner and its Retry action must take precedence over a persistent sync error")
        }
    }

    /// The reverse order of the test above: the stalled banner seats first, and a persistent sync
    /// error arriving afterward must not be able to displace it and strand its Retry action.
    @Test func aTerminalStallFollowedByAPersistentSyncErrorKeepsTheStalledBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()

            await store.send(.syncStalledTerminally(true, retriedByUser: false)) {
                $0.isSyncStalledTerminally = true
            }
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)
            #expect(store.state.priorityContent == .priorityStalled)

            await store.send(.synchronizerStateChanged(Self.syncState(.error(ZcashError.compactBlockProcessorCritical))))
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == .priorityStalled, "a persistent sync error must not displace the stronger stalled banner")
            #expect(store.state.isLatestSyncStatusError, "the error is still recorded even though it did not win the seat, so a later stall clearing can bring it back")
        }
    }

    /// Rank 0 (lost connection) still outranks the stalled lane's new rank 0.75 -- there is nothing
    /// to retry against until connectivity itself returns, so `.priority1` must still win the seat,
    /// and the stalled banner must return once connectivity is restored and Root's own flag is still
    /// set.
    @Test func aLostConnectionStillOutranksTheStalledBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()

            await store.send(.syncStalledTerminally(true, retriedByUser: false)) {
                $0.isSyncStalledTerminally = true
            }
            // Drains the seat's own delayed `.openBanner` (settling `isOpen = true`) before the next
            // send -- otherwise `.networkMonitorChanged(false)` below can race it and seat `.priority1`
            // directly instead of through the reseat detour, an equally-valid path to the same seat
            // but one that leaves `bannerSeatGeneration` at a different value than the rest of this
            // test's trace assumes.
            await store.finish()
            await store.skipReceivedActions(strict: false)
            #expect(store.state.priorityContent == .priorityStalled)

            await store.send(.networkMonitorChanged(false))
            await store.finish()
            await store.skipReceivedActions(strict: false)
            #expect(store.state.priorityContent == .priority1, "a lost connection must still outrank the stalled banner")
        }

        // Connection RETURNING is checked against its own freshly-seeded store, on a CONTROLLABLE
        // scheduler rather than `.immediate`. `.networkMonitorChanged(true)`'s handler closes the
        // disconnected banner and only THEN, after a genuine 2-second reconnect-debounce, re-walks
        // into `.priorityStalled` -- in real use that gap is what lets the close fully settle
        // first (closing has no delay of its own, so it always wins a real 2 s head start).
        // `.immediate` collapses that gap to nothing, which can let the re-walk's own request-latch
        // land before the close, which then wipes it (a clean close only lets a `.priority7`
        // request survive) and strands the slot empty -- an ordering `.immediate` can expose but a
        // real 2 s stagger never would. `DispatchQueue.test` preserves the real ordering by holding
        // the re-walk asleep until this test explicitly advances past it.
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let queue = DispatchQueue.test
            let store = makeStore(priorityContent: .priority1, isSyncStalledTerminally: true)
            store.dependencies.mainQueue = queue.eraseToAnyScheduler()

            await store.send(.networkMonitorChanged(true))
            await store.receive(\.closeAndCleanupBanner)
            await store.receive(\.closeBannerIfCurrent)
            await store.receive(\.closeBanner)
            await store.receive(\.openBannerRequest)
            #expect(store.state.priorityContent == nil, "the disconnected banner closes immediately, before the reconnect-debounce elapses")

            await queue.advance(by: .seconds(2))
            await store.receive(\.evaluatePriority2)
            await store.receive(\.evaluatePriorityStalled)
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)
            #expect(store.state.priorityContent == .priorityStalled, "the stalled banner must return once connectivity is back, since Root never cleared the terminal flag")

            // Flushes the freshly-seated banner's own delayed `.openBanner` so the store has no
            // outstanding effects left when this scope ends.
            await queue.advance(by: .seconds(2))
            await store.finish()
        }
    }

    /// MOB-1853: once the terminal flag itself clears through a GENUINE recovery (`retriedByUser:
    /// false` -- the SDK visibly making progress, backgrounding, or a rebuild that started a pass),
    /// a still-current sync error must not be left unreachable behind a banner that has just closed
    /// -- `.syncStalledTerminally(false, retriedByUser: false)` re-triggers `.priority2` when
    /// `isLatestSyncStatusError` is still set, the same way the transient-error path re-walks
    /// `.evaluatePriorityStalled` in the opposite direction. See
    /// `aRetryInitiatedClearDoesNotReseatTheErrorBanner` below for the contrasting `retriedByUser:
    /// true` case, which must NOT re-trigger the error banner.
    @Test func clearingTheTerminalFlagWhileTheErrorPersistsBringsTheErrorBannerBack() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()

            await store.send(.synchronizerStateChanged(Self.syncState(.error(ZcashError.compactBlockProcessorCritical))))
            await store.finish()
            await store.skipReceivedActions(strict: false)
            #expect(store.state.priorityContent == .priority2)

            await store.send(.syncStalledTerminally(true, retriedByUser: false)) {
                $0.isSyncStalledTerminally = true
            }
            await store.finish()
            await store.skipReceivedActions(strict: false)
            #expect(store.state.priorityContent == .priorityStalled)

            await store.send(.syncStalledTerminally(false, retriedByUser: false)) {
                $0.isSyncStalledTerminally = false
            }
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == .priority2, "clearing the terminal flag while the error is still current must bring the error banner back")
        }
    }

    /// MOB-1853: a Retry tap is an OPTIMISTIC dismiss, not a genuine clear -- Root's
    /// `.retryTerminalStallRebuild` sends this notification the instant the user taps Retry, well
    /// before the fresh rebuild attempt has any answer of its own. Re-seating the (Retry-less) error
    /// banner here, the way a genuine clear does above, would swap it in immediately and then
    /// flicker straight back to stalled once the rebuild's own outcome lands (a failure re-raises
    /// `.priorityStalled` via `.syncStalledTerminally(true, retriedByUser: false)`; a pass that
    /// actually started clears the error itself through the `.syncing` branch in
    /// `syncStatusChangedEffect`) -- a user-initiated clear must simply close, leaving the error
    /// unreachable until the rebuild decides one way or the other.
    @Test func aRetryInitiatedClearDoesNotReseatTheErrorBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()

            await store.send(.synchronizerStateChanged(Self.syncState(.error(ZcashError.compactBlockProcessorCritical))))
            await store.finish()
            await store.skipReceivedActions(strict: false)
            #expect(store.state.priorityContent == .priority2)

            await store.send(.syncStalledTerminally(true, retriedByUser: false)) {
                $0.isSyncStalledTerminally = true
            }
            await store.finish()
            await store.skipReceivedActions(strict: false)
            #expect(store.state.priorityContent == .priorityStalled)

            await store.send(.syncStalledTerminally(false, retriedByUser: true)) {
                $0.isSyncStalledTerminally = false
            }
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent != .priority2, "a user-initiated retry must not swap the stalled banner for the error banner while the fresh rebuild attempt is in flight")
            #expect(store.state.priorityContent == nil, "a user-initiated retry must simply close the stalled banner")
            #expect(store.state.isLatestSyncStatusError, "the error itself is still current -- only the RE-SEATING is suppressed, not the recorded fact of the error")
        }
    }

    /// MOB-1853: Root clears the terminal-stall flag at `.didEnterBackground` right after it stops
    /// the synchronizer, a moment before the SDK's own `.stopped` tick arrives -- that clear can hand
    /// the (Retry-less) error banner its seat back while `isLatestSyncStatusError` is still true, and
    /// nothing later would close it if the wallet came back straight to `.upToDate`. The `.stopped`
    /// tick itself must close a seated error banner, not just clear the flag.
    ///
    /// The `.stopped` send below is wrapped in `withKnownIssue`: `SyncStatus.==` (`Synchronizer.swift`)
    /// has no `(.stopped, .stopped)` case, so it falls to `default: return false`, and that poisons
    /// `SmartBanner.State`'s own (synthesized, through `SyncStatusSnapshot`) `Equatable` the instant
    /// `synchronizerStatusSnapshot.syncStatus` becomes `.stopped` -- `TestStore.send`'s own before/after
    /// diff then reports a mismatch no matter what the trailing closure predicts, purely because
    /// comparing two `.stopped` snapshots (even byte-identical ones) always answers "different". The
    /// real assertions below, on `priorityContent`/`isLatestSyncStatusError` -- plain `Equatable`
    /// types the bug never touches -- still verify the actual production behaviour; `.finish()`/
    /// `.skipReceivedActions` (rather than explicit `.receive`s) settle the resulting chain because
    /// skipping applies state directly without re-running the poisoned struct comparison.
    @Test func aStopClosesTheSeatedErrorBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()

            await store.send(.synchronizerStateChanged(Self.syncState(.error(ZcashError.compactBlockProcessorCritical))))
            await store.finish()
            await store.skipReceivedActions(strict: false)
            #expect(store.state.priorityContent == .priority2)
            #expect(store.state.isLatestSyncStatusError)

            // Marked intermittent because this only absorbs the SDK's missing `.stopped == .stopped`
            // case described above -- delete the wrapper once `SyncStatus.==` compares `.stopped` equal
            // to itself.
            await withKnownIssue(isIntermittent: true) {
                await store.send(.synchronizerStateChanged(Self.syncState(.stopped)))
            }
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == nil, "a stop must close a seated error banner instead of leaving it stranded with no Retry action")
            #expect(store.state.isLatestSyncStatusError == false)
        }
    }

    /// The `.stopped` arm only closes the error lane's OWN seat -- a banner seated by any other lane
    /// (here, the stalled banner) must keep its seat untouched. This guard already held when the
    /// `.stopped` arm only cleared the flag, and must keep holding now that it also closes the error
    /// lane's own seat. See `aStopClosesTheSeatedErrorBanner`'s doc comment for why the `.stopped`
    /// send is wrapped in `withKnownIssue`.
    @Test func aStopLeavesAnyOtherSeatedBannerAlone() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()

            await store.send(.syncStalledTerminally(true, retriedByUser: false)) {
                $0.isSyncStalledTerminally = true
            }
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)
            #expect(store.state.priorityContent == .priorityStalled)

            await withKnownIssue(isIntermittent: true) {
                await store.send(.synchronizerStateChanged(Self.syncState(.stopped)))
            }
            await store.withExhaustivity(.on) {
                await store.finish()
                await store.finish()
            }

            #expect(store.state.priorityContent == .priorityStalled, "a stop must not touch a banner seated by a different lane")
        }
    }

    /// MOB-1853: the end-to-end reproduction -- a persistent sync error is showing, the stalled
    /// banner outranks it and takes the seat, Root's `.didEnterBackground` clear re-seats the error
    /// banner while it is still current (the same hop
    /// `clearingTheTerminalFlagWhileTheErrorPersistsBringsTheErrorBannerBack` above covers on its
    /// own), and the synchronizer's own `.stopped` tick then arrives a moment later. Before the
    /// `.stopped` arm closed the error banner, the re-seated error banner was stranded on screen with
    /// no Retry action and nothing left to close it. See `aStopClosesTheSeatedErrorBanner`'s doc
    /// comment for why the `.stopped` send is wrapped in `withKnownIssue`.
    @Test func backgroundingOverAPersistentErrorEndsWithNoStaleErrorBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()

            await store.send(.synchronizerStateChanged(Self.syncState(.error(ZcashError.compactBlockProcessorCritical))))
            await store.finish()
            await store.skipReceivedActions(strict: false)
            #expect(store.state.priorityContent == .priority2)

            await store.send(.syncStalledTerminally(true, retriedByUser: false)) {
                $0.isSyncStalledTerminally = true
            }
            await store.finish()
            await store.skipReceivedActions(strict: false)
            #expect(store.state.priorityContent == .priorityStalled)

            await store.send(.syncStalledTerminally(false, retriedByUser: false)) {
                $0.isSyncStalledTerminally = false
            }
            await store.finish()
            await store.skipReceivedActions(strict: false)
            #expect(store.state.priorityContent == .priority2, "Root's background clear must bring the error banner back while the error is still current")

            await withKnownIssue(isIntermittent: true) {
                await store.send(.synchronizerStateChanged(Self.syncState(.stopped)))
            }
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.priorityContent == nil, "backgrounding over a persistent error must not leave a stale sync-error banner after the synchronizer stops")
            #expect(store.state.isLatestSyncStatusError == false)
        }
    }
}
