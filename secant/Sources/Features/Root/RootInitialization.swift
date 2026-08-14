//
//  RootInitialization.swift
//  Zashi
//
//  Created by Lukáš Korba on 01.12.2022.
//

import Combine
import ComposableArchitecture
import Combine
import Foundation
@preconcurrency import ZcashLightClientKit

/// In this file is a collection of helpers that control all state and action related operations
/// for the `Root` with a connection to the app/wallet initialization and erasure of the wallet.

// MARK: - MOB-1466: the tick loop's interval as a dependency

/// MOB-1466: `Constants.migrationTickInterval`, surfaced as a dependency so tests can override it
/// — including to `.zero`, the OFF switch (see `migrationTickLoopEffect(state:)`'s leading guard).
/// The CONSTANT stays the single source of truth: both values below read it, and production never
/// overrides this key. `testValue == liveValue` is deliberate for a plain configuration VALUE (no
/// behavior to stub, nothing a forgotten override could silently fake) — existing suites keep the
/// shipped 30s without naming this key at all.
private enum MigrationTickIntervalKey: DependencyKey {
    static let liveValue: Swift.Duration = Root.Constants.migrationTickInterval
    static let testValue: Swift.Duration = Root.Constants.migrationTickInterval
}

extension DependencyValues {
    /// The tick loop's period. `.zero` disables the automatic loop entirely; the app-open pokes
    /// (`advance(.beforeSync)` at cold start/foreground, `advance(.afterSync)` at sync edges) are a
    /// separate lane and are never affected.
    var migrationTickInterval: Swift.Duration {
        get { self[MigrationTickIntervalKey.self] }
        set { self[MigrationTickIntervalKey.self] = newValue }
    }
}

extension Root {
    enum Constants {
        static let udIsRestoringWallet = "udIsRestoringWallet"
        static let udIsResyncingWallet = "udIsResyncingWallet"
        static let udLeavesScreenOpen = "udLeaves_screen_open"
        static let noAuthenticationWithinXMinutes = 15
        /// MOB-1466: the foreground migration tick loop's wake-up period — see
        /// `migrationTickLoopEffect(state:)`. `Swift.Duration`, not `ZcashLightClientKit`'s
        /// generated protobuf `Duration`, which shadows it once that module is imported
        /// unqualified. ZERO IS THE OFF SWITCH: at `.zero` the loop never spawns at all (the
        /// effect's leading guard), while the app-open pokes are a separate lane and keep working.
        /// Surfaced to reducers/tests as `DependencyValues.migrationTickInterval`.
        ///
        /// F-C9-4 (campaign 9, 2026-08-05): this constant shipped parked at `.zero`, so the whole
        /// loop — spawn sites, conditions, self-stop — was correct and NEVER RAN: a foregrounded
        /// app drove exactly one step per open and then sat forever ("keep Zodl open" with nothing
        /// moving). Tests stayed green because they override the dependency. 30 s is the belt
        /// cadence the tick fast-path and stall guard were built against; a companion test now
        /// pins this constant non-zero so it cannot silently park again.
        static let migrationTickInterval: Swift.Duration = .seconds(30)
        /// The attribution probe's attempt budget — 9 sleeps (none after the last) at the interval below is 3.0 min, covering the tip skew.
        static let migrationGateStopProbeAttempts = 10
        /// The attribution probe's wait between `migrationAdvanceStep` reads — 9 of these between 10 attempts is 3.0 min.
        static let migrationGateStopProbeInterval: Swift.Duration = .seconds(20)
        /// How many ticks between "the loop is alive" heartbeat lines — ~10 minutes at the interval
        /// above. Approximate on purpose (see `migrationTickCount`'s doc): the log line only ever
        /// claims the loop is running, never a precise cadence.
        static let migrationTickHeartbeatEvery = 20
    }

    enum InitializationAction {
        case appDelegate(AppDelegateAction)
        case checkBackupPhraseValidation
        case checkRestoreWalletFlag(SyncStatus)
        case checkWalletInitialization
        case checkWalletConfig
        case initializeSDK(WalletInitMode)
        case initializeSDKFinished
        case staleWalletDatabaseHealed
        case presentStaleWalletHealedAlert
        case initialSetups
        case initializationFailed(ZcashError)
        case initializationSuccessfullyDone
        case loadedWalletAccounts([WalletAccount])
        case resetZashi
        case resetZashiRequest(Bool)
        case resetZashiRequestCanceled
        case respondToWalletInitializationState(InitializationState)
        case restoreExistingWallet
        case seedValidationResult(Bool)
        case synchronizerStartFailed(ZcashError)
        case registerForSynchronizersUpdate
        case retryStart
        case walletConfigChanged(WalletConfig)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func initializationReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .initialization(.appDelegate(.didFinishLaunching)):
                // MOB-1466: the LIFECYCLE MARKERS. Every migration step on iOS happens inside one
                // app-open — proving, broadcasting, the sync that observes a mining — so a `[MIG]`
                // log without open/background boundaries reads as one undifferentiated stream and
                // "what did THIS session actually do" cannot be answered from it. These three lines
                // are the sequencing spine every other `[MIG]` line hangs off.
                MigrationTrace.beginSession(cause: .coldLaunch, tip: sdkSynchronizer.latestState().latestBlockHeight)
                state.appStartState = .didFinishLaunching
                // TODO: [#704], trigger the review request logic when approved by the team,
                // https://github.com/Electric-Coin-Company/zashi-ios/issues/704
                return .merge(
                    .run { send in
                        try await mainQueue.sleep(for: .seconds(0.5))
                        await send(.initialization(.initialSetups))
                    }
                    .cancellable(id: state.DidFinishLaunchingId, cancelInFlight: true),
                    // Zodl Bridge: start the UDS listener once per launch (RootBridge.swift).
                    // No-op on iOS — the live client there is inert by construction.
                    .send(.bridge(.startListener))
                )

            case .initialization(.appDelegate(.willEnterForeground)):
                // See the cold-launch marker above. The tip rides along because it is the one piece
                // of context that decides what this session is allowed to do, and it survives
                // backgrounding in memory, so it is truthful at this exact moment.
                MigrationTrace.beginSession(cause: .foreground, tip: sdkSynchronizer.latestState().latestBlockHeight)
                if state.featureFlags.appLaunchBiometric {
                    let now = Date()
                    let before = Date.init(timeIntervalSince1970: TimeInterval(state.lastAuthenticationTimestamp))
                    if let xMinutesAgo = Calendar.current.date(byAdding: .minute, value: -Constants.noAuthenticationWithinXMinutes, to: now),
                       before < xMinutesAgo {
                        state.splashAppeared = false
                    }
                }
                state.appStartState = .willEnterForeground
                // Placed after the biometric re-auth block above so that block's possible
                // `splashAppeared = false` has already landed before the safety gate reads it.
                // The tip survives backgrounding in memory (`sdkSynchronizer.latestState()`),
                // which is what makes this call site immediate rather than waiting for a fresh
                // sync tick to repopulate it via `.synchronizerStateChanged`.
                presentIronwoodAnnouncementIfNeeded(state: &state, tip: sdkSynchronizer.latestState().latestBlockHeight)
                // MOB-1466: "the open breaks the loop's sleep" — a fresh foreground always
                // restarts the tick loop's 30s countdown from zero (`cancelInFlight: true` inside
                // `migrationTickLoopEffect`), whichever branch below this open actually takes.
                let migrationTickEffect = migrationTickLoopEffect(state: state)
                // MOB-1466 — STALENESS. iOS paints the previous frame on foreground, so until the
                // re-derivation below returns (seconds, not milliseconds) the smart banner states
                // last session's conclusion with full confidence. Raising `.checkingStatus` FIRST,
                // synchronously in this reducer, is what stops the user reading a promise that is
                // no longer true. It is a no-op unless the migration lane already owns the banner.
                //
                // Sits ALONGSIDE the tick effect above rather than replacing it — the two are
                // different halves of one problem. The tick keeps an ALREADY-OPEN screen fresh;
                // this covers the gap before the first answer of a NEW foreground, which no tick
                // interval can close because the stale frame is painted before any timer starts.
                let migrationCheck: Effect<Action> = state.featureFlags.migration
                    ? .send(.home(.smartBanner(.migrationForegroundCheckStarted)))
                    : .none
                // (#7) A fresh foreground grants a fresh one-shot start-failure retry — reset here
                // as well as at background, because an inactive-without-background cycle never
                // runs the background boundary at all.
                state.didScheduleStartFailureRetry = false
                if state.isLockedInKeychainUnavailableState || !sdkSynchronizer.latestState().syncStatus.isPrepared {
                    return .merge(migrationTickEffect, migrationCheck, .send(.initialization(.initialSetups)))
                } else {
                    return .merge(migrationTickEffect, migrationCheck, .send(.initialization(.retryStart)))
                }
                
            case .initialization(.appDelegate(.migrationNotificationTapped(let accountUUID, let isTorFailure))):
                // A poke was tapped. LAND ON HOME — do NOT open the migration flow.
                //
                // DELIBERATE REVERSAL of Phase 4, on Andrea's rule (relayed 2026-08-03): the smart
                // banner is the story, the migration screen is only the detail. Auto-navigating into
                // that screen put the user in front of the one surface that CANNOT be trusted to be
                // fresh on arrival — it renders a snapshot, while the banner re-derives per session.
                // Every banner-vs-screen contradiction reported this week arrived through a door
                // like this one.
                //
                // So the tap now does exactly what tapping the app icon does, and no more. That is
                // not a weaker guarantee, it is the SAME one: entry parity (I4) stops being an
                // invariant we maintain and becomes true by construction, because both entrances
                // are now literally the same code path.
                //
                // Home rather than "stay where you are", and the distinction matters: a tap is an
                // explicit request to see what the notification is about, and what it is about is
                // the banner. Backgrounding in Advanced Settings and tapping a migration poke should
                // not leave the user in Advanced Settings. A plain foreground has no such signal and
                // is deliberately left alone.
                MigrationTrace.notificationTapped()
                _ = isTorFailure
                _ = accountUUID
                // THE LATCH IS GONE, and its absence is the point. `pendingMigrationNotificationTap`
                // existed only because the tap NAVIGATED: a tap arriving during cold launch, before
                // flags or the SDK were up, would have been swallowed, so it had to be stored and
                // replayed. Landing on Home needs none of that — a cold launch already lands there,
                // so the tap is idempotent with the app's own startup and can never be "too early".
                state.path = nil
                MigrationTrace.event("notification tap → Home (no deeplink; the banner is the story)")
                return .none

            case .initialization(.appDelegate(.migrationPokeLandedInForeground(let accountUUID))):
                // F-C9-4 companion: the poke landed while we're frontmost. D9 presented nothing,
                // so nobody can tap it — the landing itself is the drive. The `.tick` lane is the
                // belt lane: single-flight latched, exempt from the R0 open-lane credits, and a
                // no-op ("waiting"/"idle") when the estimate ran ahead of the chain — in which
                // case the advance's own reconcile re-arms the next poke and the chain of pokes
                // continues. No navigation, no state: exactly a tick that fired early.
                MigrationTrace.event("🔔 poke landed while foregrounded — driving the tick belt (D9: no banner)")
                _ = accountUUID
                return .run { _ in
                    await migrationManager.advance(.tick)
                }

            case .initialization(.appDelegate(.didEnterBackground)):
                // See the cold-launch marker above. `sdkSynchronizer.stop()` on the next line is
                // why this boundary matters so much to a migration run: sync does not merely pause
                // here, it STOPS, and nothing restarts it until the next foreground's `.retryStart`.
                // Anything the run was waiting to observe — a preparation mining, a transfer
                // confirming — waits for the user to come back.
                MigrationTrace.endSession(reason: "BACKGROUND — sync stopping")
                sdkSynchronizer.stop()
                state.bgTask?.setTaskCompleted(success: false)
                state.bgTask = nil
                state.appStartState = .didEnterBackground
                state.isLockedInKeychainUnavailableState = false
                // Audit 2026-08-03 (#12): the migration edge detector resets at every stop
                // boundary — the state stream is cancelled below BEFORE the SDK's `.stopped`
                // emission can arrive, so without this the flag stays `true` across the round
                // trip and the next foreground's first `.upToDate` snapshot reads as "no edge":
                // no `recordSyncCompleted()`, no `advance(.afterSync)` for that whole foreground.
                state.wasSyncUpToDateForMigration = false
                // (#7) The one-shot start-failure retry is a foreground mechanism, same as the
                // tick loop: cancel it and reset its latch so the next foreground starts clean.
                state.didScheduleStartFailureRetry = false
                // Tear down ALL synchronizer-driven subscriptions (plus the pending-transactions
                // poller) over the now-stopped synchronizer; `.retryStart` on foreground rebuilds
                // every one of them.
                return .merge(
                    .cancel(id: state.CancelStateId),
                    .cancel(id: state.CancelTransactionsStateId),
                    .cancel(id: state.CancelEventId),
                    .cancel(id: state.CancelPendingTxPollId),
                    // MOB-1466: the tick loop is a FOREGROUND-only mechanism — the app cannot poll
                    // anything once backgrounded (there is no background lane), so its whole reason
                    // to exist stops the instant sync itself does, on the same boundary. The next
                    // foreground respawns it fresh if the spawn condition still holds.
                    .cancel(id: state.migrationTickCancelId),
                    .cancel(id: state.startFailureRetryCancelId),
                    // Audit 2026-08-03 (#19): the merged gate subscription (SDK stream + app feed)
                    // is FOREGROUND machinery like everything above — left alive, a background
                    // gate emission ran the full resume (clearing the arming flags, sending
                    // `.retryStart`, restarting the sync this boundary just stopped). The next
                    // foreground's `.registerForSynchronizersUpdate` respawns it.
                    .cancel(id: state.migrationSyncGateCancelId)
                )

            case .initialization(.appDelegate(.backgroundTask(let task))):
                let keysPresent: Bool = (try? walletStorage.areKeysPresent()) ?? false
                if state.appStartState == .didFinishLaunching {
                    state.appStartState = .backgroundTask
                    if keysPresent {
                        state.bgTask = task
                        return .none
                    } else {
                        state.isLockedInKeychainUnavailableState = true
                        task.setTaskCompleted(success: false)
                        return .cancel(id: state.DidFinishLaunchingId)
                    }
                } else {
                    state.bgTask = task
                    state.appStartState = .backgroundTask
                    return .run { send in
                        await send(.initialization(.retryStart))
                    }
                }
                
            case .synchronizerStateChanged(let latestState):
                // Must run above the `selectedWalletAccount` guard and the background-task
                // branch below — both early-return, but the announcement gate has to keep
                // evaluating on every sync tick regardless of whether an account is selected
                // (normal on a fresh install) or a background task is in flight (already
                // excluded by `canPresentIronwoodAnnouncement`'s own `bgTask == nil` term).
                presentIronwoodAnnouncementIfNeeded(state: &state, tip: latestState.data.latestBlockHeight)

                let snapshot = SyncStatusSnapshot.snapshotFor(state: latestState.data.syncStatus)

                // Reconcile migration state on the EDGE into `.upToDate` — never on every tick while
                // already synced, which would storm `reconcile()` at the tip. Piggybacks on this
                // existing `stateStream()` subscription rather than opening a second one.
                // `recordSyncCompleted()` re-keys the app's SEND gate off the same edge: a
                // just-completed sync briefly disables migration sends, which is the app-direction
                // half of the privacy gate (the SDK owns the other direction).
                let didJustReachUpToDate = snapshot.syncStatus == .upToDate && !state.wasSyncUpToDateForMigration
                state.wasSyncUpToDateForMigration = snapshot.syncStatus == .upToDate
                let migrationReconcileEffect: Effect<Action> = didJustReachUpToDate
                    ? .merge(
                        .run { [migrationManager] _ in
                        migrationManager.recordSyncCompleted()
                        // (P3's invalidation sweep used to run here, first. Both of its jobs are
                        // the ENGINE's now: foreign-spent funding notes are recorded by the
                        // engine's satisfiability oracle, and a broadcast this process submitted
                        // but failed to record is promoted on every `migrationAdvanceStep` —
                        // automatically, not only when this edge remembered to ask.)
                        // THE DRIVER at its second and last moment of the app-open, and this edge is
                        // the only correct place for it: sync has just reached the tip, so every
                        // settled anchor boundary is now witnessable and the engine's answer is
                        // computed against fresh data.
                        //
                        // This used to be three hand-sequenced calls — prove sweep, reconcile, re-arm
                        // — chosen by this call site rather than by the engine. That is exactly the
                        // shape the driver replaces: the app decided WHAT to do here and the engine
                        // was only ever consulted about broadcasts, so the two steps with no other
                        // discharge in the app (`.rebuild`, `.requiresAttention`) fell through this
                        // edge untouched, every time, forever. `advance` asks and obeys instead, and
                        // still does all three of those things when `.prove` is the answer.
                        //
                        // `accountUUID` is no longer threaded in: the driver arms wake-ups for every
                        // candidate account, not just the selected one, which is what a wallet with a
                        // Zodl and a Keystone account migrating in parallel actually needs.
                        await migrationManager.advance(.afterSync)
                        },
                        // The belt for SmartBanner's own `.upToDate` recheck (field-caught
                        // 2026-08-03, the launch race on an already-synced wallet): this edge is
                        // the one place that provably knows sync just completed, so it also sends
                        // the banner funnel — independent of the slot's occupant and the banner's
                        // own stream timing. A funnel re-render is a no-op when nothing changed;
                        // feature-gated like every other funnel caller.
                        state.featureFlags.migration
                            ? .send(.home(.smartBanner(.migrationReevaluationRequested)))
                            : .none
                    )
                    : .none

                // MOB-1466 (07-31, field-caught): `migrationReconcileEffect` must reach EVERY return
                // below, not just this one. It used to be returned here and nowhere else — so the
                // whole sync-complete migration edge (invalidation sweep, prove sweep, reconcile,
                // notification arming) ran only when NO account was selected, which is precisely the
                // case with nothing to migrate. On every real wallet the effect was built and thrown
                // away by the next `return`.
                //
                // What that looked like on a device: the engine asked to prove preparation (0,0) at
                // every open, forever. Nothing proved it, so nothing was ever broadcast, so the run
                // sat at 0-of-12 with every preparation reading "Ready now" — a committed migration
                // that could not take its first step. Giving the sweeps their callers (A24/A28) was
                // necessary and not sufficient: the callers existed and their effect was discarded
                // one line later.
                //
                // Merged into each return rather than hoisted, because the paths below legitimately
                // return different things and each one is reachable at a sync-complete edge. The
                // effect is `.none` unless this tick IS that edge, so merging costs nothing.
                guard let account = state.selectedWalletAccount else {
                    return migrationReconcileEffect
                }
                
                // update flexa balance
                if let accountBalance = latestState.data.accountsBalances[account.id] {
                    // Pool-agnostic accessors: sum sapling + orchard + ironwood (and any future
                    // shielded pool) instead of hand-summing individual pools.
                    let shieldedBalance = accountBalance.shieldedSpendableValue
                    let shieldedWithPendingBalance = accountBalance.shieldedTotal()

                    flexaHandler.updateBalance(shieldedWithPendingBalance, shieldedBalance)
                }

                // handle possible service unavailability
                if case .error(let error) = snapshot.syncStatus, checkUnavailableService(error) {
                    if state.walletStatus != .disconnected {
                        state.alert = AlertState.serviceUnavailable()
                    }
                    state.wasRestoringWhenDisconnected = state.walletStatus == .restoring
                    state.$walletStatus.withLock { $0 = .disconnected }
                } else if case .syncing = snapshot.syncStatus, state.walletStatus == .disconnected {
                    state.$walletStatus.withLock { $0 = state.wasRestoringWhenDisconnected ? .restoring : .none }
                }

                // [#1755 / slipstream] Drive the restoring/resyncing LABEL from the SDK's durable
                // `isRecovering` signal (recovery_progress incomplete = a from-birthday backfill is in
                // progress). It's recomputed from data.db every launch, so a kill mid-restore relaunches
                // as .restoring with no reliance on a persisted guess, and a stale flag self-corrects.
                // A user-initiated RESYNC is the same engine operation (isRecovering can't see intent),
                // so we honor the persisted resync intent for the label. `.disconnected` (set above) is
                // left untouched; resync completion still clears via the existing up-to-date path.
                let recovering = latestState.data.isRecovering
                if state.walletStatus != .disconnected {
                    if recovering {
                        if state.walletStatus != .restoring, state.walletStatus != .resyncing {
                            let resyncing = userDefaults.objectForKey(Constants.udIsResyncingWallet) as? Bool ?? false
                            state.$walletStatus.withLock { $0 = resyncing ? .resyncing : .restoring }
                        }
                        state.isRestoringWallet = true
                    } else if state.walletStatus == .restoring {
                        state.isRestoringWallet = false
                        userDefaults.remove(Constants.udIsRestoringWallet)
                        userDefaults.remove(Constants.udIsResyncingWallet)
                        state.$walletStatus.withLock { $0 = .none }
                    }
                }

                // handle BCGTask
                guard state.bgTask != nil else {
                    return .merge(
                        migrationReconcileEffect,
                        .send(.initialization(.checkRestoreWalletFlag(snapshot.syncStatus)))
                    )
                }
                
                var finishBGTask = false
                var successOfBGTask = false
                
                switch snapshot.syncStatus {
                case .upToDate:
                    successOfBGTask = true
                    finishBGTask = true
                    if state.isRestoringWallet {
                        userDefaults.remove(Constants.udIsRestoringWallet)
                        userDefaults.remove(Constants.udIsResyncingWallet)
                        state.$walletStatus.withLock { $0 = .none }
                    }
                    state.isRestoringWallet = false
                case .stopped, .error:
                    successOfBGTask = false
                    finishBGTask = true
                default: break
                }
                
                if finishBGTask  {
                    LoggerProxy.event("BGTask setTaskCompleted(success: \(successOfBGTask)) from TCA")
                    state.bgTask?.setTaskCompleted(success: successOfBGTask)
                    state.bgTask = nil
                    // Audit 2026-08-03 (#12): same edge-detector reset as `didEnterBackground` —
                    // this path cancels the state stream with the flag frequently `true` (the
                    // task just synced to `.upToDate`), and the next foreground's re-subscription
                    // would otherwise see `.upToDate == .upToDate`: no edge, no
                    // `recordSyncCompleted()`, no `advance(.afterSync)` for that foreground.
                    state.wasSyncUpToDateForMigration = false
                    return .merge(
                        migrationReconcileEffect,
                        .cancel(id: state.CancelStateId),
                        .cancel(id: state.CancelTransactionsStateId),
                        .cancel(id: state.CancelEventId),
                        .cancel(id: state.CancelPendingTxPollId)
                    )
                }

                return .merge(
                    migrationReconcileEffect,
                    .send(.initialization(.checkRestoreWalletFlag(snapshot.syncStatus)))
                )
                
            case .initialization(.checkRestoreWalletFlag(let syncStatus)):
                if state.isRestoringWallet && syncStatus == .upToDate {
                    state.isRestoringWallet = false
                    userDefaults.remove(Constants.udIsRestoringWallet)
                    userDefaults.remove(Constants.udIsResyncingWallet)
                    state.$walletStatus.withLock { $0 = .none }
                }
                return .none

            case .initialization(.synchronizerStartFailed):
                // Audit 2026-08-03 (#7): this was `return .none` — a dead end. A transient start
                // failure (network blip, Tor bootstrap, disconnected) now schedules ONE bounded
                // delayed retry per foreground; a second failure waits for the next external
                // trigger (a foreground, a gate emission) rather than self-retrying in a loop.
                // The subscriptions were re-armed by the catch that sent this action, so the gate
                // and state streams keep flowing meanwhile.
                guard !state.didScheduleStartFailureRetry else { return .none }
                state.didScheduleStartFailureRetry = true
                return .run { send in
                    try await continuousClock.sleep(for: .seconds(15))
                    await send(.initialization(.retryStart))
                }
                .cancellable(id: state.startFailureRetryCancelId, cancelInFlight: true)
                
            // THE OTHER HALF of `SDKSynchronizerClient.stopSyncBeforeMigrationBroadcast()`
            // (matrix B12). A migration broadcast stops sync so the two are not correlated; without
            // this handler that sync never restarts and the wallet sits dead for the session.
            //
            // Resuming is checked INDEPENDENT of `isGenuineChange`, deliberately. Two edges need it:
            //  - a foreground broadcast stopped sync while no `.retryStart` happened to be running,
            //    so `syncDeferredByMigrationGate` was never set;
            //  - a broadcast that failed PRE-FLIGHT (a Tor bootstrap error, say) never reached the
            //    SDK's gate-setting code at all, so no `true -> false` transition will EVER arrive.
            // `migrationStoppedSyncForBroadcast` covers both: it stays set until the next
            // `.migrationSyncGateChanged(false)` from ANY source, which this resumes on rather than
            // letting the dedupe swallow it as "no change".
            //
            // `reconcile()` stays gated on a genuine change — it drives banner/re-entry derivation,
            // an unrelated concern that should not re-run on every re-push.
            case .migrationGateDeferredSyncStart:
                // The refusal handlers in `.initializeSDK`/`.retryStart` arm this BEFORE running
                // their broadcast session, so the clearing edge below resumes even when that
                // session finds nothing to broadcast (the buffer-shape refusal, where
                // `migrationStoppedSyncForBroadcast` never gets set either).
                state.syncDeferredByMigrationGate = true
                return .none

            // MOB-1466: THE TICK LOOP's one wake-up. See `migrationTickLoopEffect(state:)` for how
            // this got sent, and its own doc for why calling the driver lives HERE rather than in
            // the loop's `.run` body: only a reducer case can return `.cancel`/`.send` in response
            // to what the driver answers.
            //
            // I5 (RESUME INVARIANT): pre-arms `syncDeferredByMigrationGate` BEFORE the advance call
            // that may broadcast — the same flag `.migrationGateDeferredSyncStart` already arms for
            // the gate-refusal sites elsewhere in this file. Three sync states can exist the instant
            // a tick's broadcast lands: (a) actively syncing — `stopSyncBeforeMigrationBroadcast`
            // stops it and sets the shared `migrationStoppedSyncForBroadcast` flag itself, unchanged
            // by this pre-arm; (b) already stopped-and-deferred — `syncDeferredByMigrationGate` was
            // already true; (c) started but IDLE AT THE TIP — nothing for
            // `stopSyncBeforeMigrationBroadcast` to stop, so NEITHER flag would otherwise get set by
            // the broadcast itself, and once the SDK's own post-broadcast gate later clears,
            // `.migrationSyncGateChanged(false)`'s `shouldResume` computation would find both flags
            // false and never send `.retryStart` — sync stays unresumed for the rest of the
            // foreground. (a) and (b) already pass bare (pinned in
            // `RootMigrationTickLoopTests`/`RootMigrationGateRefusalTests`); this line is what makes
            // (c) pass too.
            //
            // Unconditional rather than gated on "did the fast path hold": that answer is
            // driver-internal (the plan stays pure — see `MigrationStepPlan`'s doc — and
            // `MigrationStepVerdict.held`'s reason is a free-form string, not a structured signal
            // worth pattern-matching on here). A QUIET tick pre-arms this flag for nothing, but that
            // is harmless: the flag just sits `true`, unread, until SOME later genuine gate
            // transition consumes it — at worst one extra, idempotent `.retryStart`.
            case .migrationTick:
                state.migrationTickCount += 1
                let tickNumber = state.migrationTickCount
                let logHeartbeat = tickNumber.isMultiple(of: Constants.migrationTickHeartbeatEvery)
                return .concatenate(
                    .send(.migrationGateDeferredSyncStart),
                    .run { [migrationManager] send in
                        let verdict = await migrationManager.advance(.tick)
                        if logHeartbeat {
                            LoggerProxy.event("\(MigrationManagerImpl.logTag) migration tick loop alive — last verdict: \(verdict)")
                        }
                        await send(.migrationTickAdvanced(verdict))
                    }
                )

            case .migrationTickAdvanced(let verdict):
                switch verdict {
                // Terminal/empty: nothing is left for the loop to help with. Self-stop — the next
                // foreground respawns it if a fresh run starts a new candidate.
                //
                // `.notApplicable` is deliberately NOT in this set (audit 2026-08-03, P1): the
                // driver answers it for TRANSIENT shapes too — a tip that momentarily reads 0
                // during an engine restart, an account list momentarily empty during a switch —
                // and cancelling on those killed the loop for the rest of the session over a
                // wobble. A live loop's 30 s guard re-check costs nothing; genuine
                // never-applicable wallets never spawn the loop in the first place (the spawn
                // condition gates on activation and a scheduled candidate).
                case MigrationStepVerdict.complete, MigrationStepVerdict.noRun:
                    return .cancel(id: state.migrationTickCancelId)
                // SUBSTANTIVE — the same set `MigrationStepVerdict.isQuietForTick` calls NOT quiet,
                // esp. `.broadcast`: a tick just changed something about the run, so re-derive the
                // banner rather than waiting for a sync transition that a tick, by construction,
                // never causes. Reuses the SAME reevaluation `.migrationCoordFlow(.flowFinished)`
                // already sends after a manual delivery (see `RootCoordinator.swift`) — harmless
                // when nothing visibly changed, since the re-read just returns the same variant.
                case MigrationStepVerdict.broadcast, MigrationStepVerdict.rebuilt, MigrationStepVerdict.needsUser,
                     MigrationStepVerdict.failed, MigrationStepVerdict.proved,
                     MigrationStepVerdict.reevaluating:
                    return .send(.home(.smartBanner(.migrationReevaluationRequested)))
                // Quiet: nothing changed, and arming/logging already handled the rest inside the
                // driver — see `advance(phase:)`'s tick-specific hygiene. `.notApplicable` sits
                // here (not in the cancel arm above) because the driver also answers it for
                // transient wobbles — see the cancel arm's comment.
                case MigrationStepVerdict.held, MigrationStepVerdict.idle, MigrationStepVerdict.deferredToPhase,
                     MigrationStepVerdict.skipped, MigrationStepVerdict.notApplicable:
                    return .none
                }

            case .migrationSyncGateChanged(let isBlocked):
                @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false

                let isGenuineChange = isBlocked != state.lastMigrationSyncGateBlocked
                let shouldResume = !isBlocked && (state.syncDeferredByMigrationGate || migrationStoppedSyncForBroadcast)
                guard isGenuineChange || shouldResume else { return .none }

                state.lastMigrationSyncGateBlocked = isBlocked
                let reconcileEffect: Effect<Action> = isGenuineChange
                    ? .run { [migrationManager] _ in await migrationManager.reconcile() }
                    : .none
                // The probe (below) is moot once the gate unblocks — the false edge is also the
                // resume half's edge, and a stop landing AFTER resume would re-strand sync.
                let probeCancelEffect: Effect<Action> = isGenuineChange && !isBlocked
                    ? .cancel(id: state.migrationGateStopProbeCancelId)
                    : .none

                // MOB-1466 (foreground wedge, field-caught 2026-08-02): THE STOP HALF of this
                // handler's pair. `blocked == true` means "this wallet should not be syncing", but
                // the SDK enforces that only on a NEW start() — an already-running engine keeps
                // completing passes right through it. Stopping the running sync here is what makes
                // the engine actually observe the refusal.
                //
                // 2026-08-07: the wedge this was FIRST written for is gone. Back then `blocked`
                // could mean "a post-broadcast buffer is running", and every completed pass
                // re-armed the app-side post-sync send window before it could expire, so the tick
                // lane held forever behind a sliding deadline (nine `broadcast(id:)` reads over
                // 15+ minutes). Both timed windows have since been deleted as identifiable
                // patterns, so there is no sliding deadline left to outrun. What remains is
                // narrow and still worth doing: `blocked` now means a submission is genuinely in
                // flight, and letting a running engine sync across it is exactly the adjacency
                // the SDK is refusing a start for.
                //
                // Scoped to the runs whose broadcasts RIDE ticks: `.privateScheduled` with manual
                // delivery off. An `.immediate` run delivers from the open lanes and a manual-
                // delivery run delivers by hand (its Send-now lane performs its own stop) —
                // stopping their sync would strand them with no lane to use the silence. The
                // SDK's gate is WALLET-wide (`isMigrationSyncBlocked()` has no per-account view),
                // so eligibility is checked over the same candidate set
                // `migrationTickLoopEffect(state:)` scopes itself by
                // (`MigrationDerivations.candidateAccountUUIDs`), not just the selected account —
                // a second candidate's scheduled run must be able to stop sync even when the
                // selected account is immediate-mode or none is selected. Attribution is no
                // longer a residual gap: the probe below reads each candidate's OWN
                // `migrationAdvanceStep`, the per-account view the wallet-wide gate itself does
                // not have, and only stops sync once a tick-deliverable candidate's step answers
                // `.broadcast` — a manual-delivery or immediate account's ready broadcast can
                // still be what tripped the gate, and in that shape the probe exhausts its
                // attempts and deliberately leaves sync running rather than pausing a candidate
                // for a broadcast nothing automatic will send.
                //
                // Also gated on the tick loop's own off switch (`migrationTickInterval >
                // Swift.Duration.zero`, the same dependency `migrationTickLoopEffect(state:)`
                // reads): with the loop disabled nothing will ever consume the silence this buys,
                // so stopping here would strand sync for the rest of the foreground instead of
                // helping it.
                //
                // `stopStartedSyncForMigrationGate()` (not `stopSyncBeforeMigrationBroadcast()`,
                // the broadcast lanes' own stop): its predicate is "started" (`.syncing` OR
                // `.upToDate`), not `isSyncing()` — the wedge is an engine idling AT the tip
                // between blocks, where `isSyncing()` reads false at every tick, which is exactly
                // why the broadcast lanes' guard could never serve this call site. Same contract
                // as its sibling otherwise: sets `migrationStoppedSyncForBroadcast` only when it
                // genuinely stopped something — which is exactly what arms this same handler's
                // resume half for the `false` edge. One stop per false->true transition (the
                // `isGenuineChange` dedupe); the SDK's own start() throw backstops any restart
                // attempt while blocked. Merged into the same effect: a re-spawn of
                // `migrationTickLoopEffect(state:)`, idempotent and self-guarding, because a run
                // can be COMMITTED mid-session with no loop yet running (the loop only spawns at
                // app-open) — a stop with no lane left to consume its silence would strand sync
                // instead of freeing it.
                let tickLoopCanConsumeTheStop = migrationTickInterval > Swift.Duration.zero
                let stopEffect: Effect<Action>
                // Short-circuited deliberately, not pre-computed: `migrationMode` must only be
                // READ when a stop is otherwise on the table. Suites that drive
                // `.migrationSyncGateChanged` without a `.privateScheduled` scenario in mind
                // (e.g. `RootMigrationGateRefusalTests`) never stub the closure — calling it
                // unconditionally would trap on every gate emission, not just the ones this
                // handler's stop half actually cares about.
                if isGenuineChange && isBlocked && tickLoopCanConsumeTheStop {
                    let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
                        selectedAccountUUID: state.selectedWalletAccount?.id,
                        walletAccounts: state.walletAccounts
                    )
                    let stoppableCandidateUUIDs = accountUUIDs.filter { accountUUID in
                        migrationManager.migrationMode(accountUUID) == MigrationMode.privateScheduled
                    }
                    stopEffect = stoppableCandidateUUIDs.isEmpty
                        ? .none
                        : .merge(
                            // THE CONSUMER LANE, GUARANTEED ALIVE. The tick loop spawns at
                            // app-open/foreground and self-cancels on a `.noRun` verdict — a run
                            // COMMITTED mid-session has no loop until the next open, so a stop
                            // armed for it would pause sync with nothing left to use the
                            // silence. Re-spawning here (idempotent — `cancelInFlight: true`
                            // restarts the 30 s countdown) pins the invariant instead of the
                            // schedule: whenever a stop can arm, the lane that consumes it is
                            // running. When the loop is ALREADY alive, this restarts its
                            // countdown from zero rather than leaving the in-flight one be — a
                            // bounded, accepted cost (worst case one extra ~30 s wait), not a
                            // correctness issue.
                            migrationTickLoopEffect(state: state),
                            .run { [sdkSynchronizer, continuousClock] _ in
                                // THE ATTRIBUTION PROBE. The SDK's gate is wallet-wide; a
                                // manual-delivery or immediate account's ready broadcast can be
                                // what blocked it, and pausing sync for a send nothing automatic
                                // performs would strand the wallet. `migrationAdvanceStep` IS the
                                // per-account view the gate lacks: step priority puts
                                // `.broadcast` first, so `.broadcast(id:)` for an account means
                                // exactly "proved, schedule-due" — the same predicate the gate's
                                // ready-broadcast check sees. Stop only when a TICK-DELIVERABLE
                                // account answers `.broadcast`.
                                //
                                // Probed, not read once: the gate can flip on the wall-clock
                                // ESTIMATED tip while the step still reads the scanned tip — sync
                                // is still running while this probes, so the step catches up
                                // within a block or two. Ten attempts, 20 s apart (3.0 min total)
                                // cover that skew with margin; exhausting them means the blocker belongs to
                                // a non-deliverable account, and sync is deliberately left
                                // running — today's behavior for exactly that case. Cancelled by
                                // the gate's false edge (the probe's work is moot once unblocked).
                                for attempt in 0..<Root.Constants.migrationGateStopProbeAttempts {
                                    for accountUUID in stoppableCandidateUUIDs {
                                        let advance = try? await sdkSynchronizer.migrationAdvanceStep(accountUUID)
                                        if case .broadcast = advance?.step {
                                            // RACE GUARD: `.cancel(id:)` is cooperative — it cannot abort the
                                            // `migrationAdvanceStep` await already in flight above, and `try?`
                                            // swallows any cancellation error that call itself might throw. Without
                                            // this checkpoint, a false edge racing this exact read could land the
                                            // stop AFTER the gate cleared and resume already restarted sync.
                                            guard !Task.isCancelled else { return }
                                            await sdkSynchronizer.stopStartedSyncForMigrationGate()
                                            return
                                        }
                                    }
                                    if attempt < Root.Constants.migrationGateStopProbeAttempts - 1 {
                                        try await continuousClock.sleep(for: Root.Constants.migrationGateStopProbeInterval)
                                    }
                                }
                                LoggerProxy.event(
                                    """
                                    [MIG] blocked gate: no tick-deliverable account answers .broadcast after \
                                    probing — leaving sync running (manual/immediate blocker)
                                    """
                                )
                            }
                            .cancellable(id: state.migrationGateStopProbeCancelId, cancelInFlight: true)
                        )
                } else {
                    stopEffect = .none
                }

                guard shouldResume else { return .merge(reconcileEffect, stopEffect, probeCancelEffect) }

                // The flags this resume consumed are cleared by `.retryStart` itself, PAST its
                // guards (audit 2026-08-03, #12): clearing them here — before the send — meant a
                // disk-space or not-yet-prepared early return swallowed the resume with the flags
                // already gone, and with `lastMigrationSyncGateBlocked` now false and the SDK
                // stream collapsing duplicates, no later emission re-attempted it.
                return .merge(
                    reconcileEffect,
                    probeCancelEffect,
                    // A broadcast just landed (or failed) — the next window moved either way.
                    .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] _ in
                        await migrationManager.armNextWindowNotifications(accountUUID)
                    },
                    .send(.initialization(.retryStart))
                )

            case .initialization(.retryStart):
                if !diskSpaceChecker.hasEnoughFreeSpaceForSync() {
                    state.destinationState.preNotEnoughFreeSpaceDestination = state.destinationState.internalDestination
                    return .send(.destination(.updateDestination(.notEnoughFreeSpace)))
                } else if let preNotEnoughFreeSpaceDestination = state.destinationState.preNotEnoughFreeSpaceDestination {
                    state.destinationState.internalDestination = preNotEnoughFreeSpaceDestination
                    state.destinationState.preNotEnoughFreeSpaceDestination = nil
                }
                // Try the start only if the synchronizer has been already prepared
                guard sdkSynchronizer.latestState().syncStatus.isPrepared else {
                    return .none
                }
                // (The Send-now silence-window fence read that lived here was REMOVED 2026-08-07
                // with the Send-now lanes — nothing sets the fence anymore.)
                // PAST the guards: consume the migration-resume arming flags (audit 2026-08-03,
                // #12 — see the gate-resume comment above). An early return above leaves them
                // armed so the gate's next emission can retry the whole resume.
                state.syncDeferredByMigrationGate = false
                @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
                $migrationStoppedSyncForBroadcast.withLock { $0 = false }
                return .run { [state] send in
                    do {
                        // ZIP 318 session separation, decided BEFORE the wire is touched: if any
                        // account has a proven transfer due, this open is a BROADCAST session and
                        // must not initiate sync. Stopping an in-flight sync (the reactive gate
                        // below) is too late for the privacy property — the correlation exists the
                        // moment sync connects. See `MigrationVisit`.
                        // MOB-1466 (Lukas, 2026-08-07 — THE ~10 Hz SPIN): did this pass touch the
                        // synchronizer at all? Only a pass that did needs its streams
                        // re-registered. See the guard on `.registerForSynchronizersUpdate` at the
                        // bottom of this block for the loop this closes.
                        var startedSyncThisPass = false
                        if await migrationManager.visitKind() == .send {
                            LoggerProxy.event("\(MigrationManagerImpl.logTag) skipping sync start — broadcast session")
                            // MOB-1466 (N4, field-caught 2026-08-01): ARM THE RESUME, exactly as the
                            // refusal handler below does. This branch is the one that was missing it,
                            // and it is the COMMON path — the planned broadcast session, the one
                            // `visitKind()` classifies up front.
                            //
                            // Without it the run freezes for the rest of the app-open. The chain:
                            // sync never starts here, so `syncDeferredByMigrationGate` stays false;
                            // `stopSyncBeforeMigrationBroadcast()` then early-returns on
                            // `guard isSyncing()` — correctly, there was nothing to stop — so
                            // `migrationStoppedSyncForBroadcast` stays false too. The broadcast
                            // succeeds, the SDK's post-broadcast buffer blocks sync for 180 s, and
                            // when it clears `.migrationSyncGateChanged(false)` computes
                            // `shouldResume = !isBlocked && (false || false)` and returns without
                            // `.retryStart`. Sync never resumes. No polling, no sync-complete edge,
                            // no reconcile, no pokes — the UI holds whatever it last rendered.
                            //
                            // On the device that was six minutes of "Preparing transaction…" with
                            // spinners and an EMPTY LOG, cured only by backgrounding and
                            // foregrounding (which reaches `.retryStart` by another road). The
                            // tester's reading — "I assume it's finished but UI is stale" — was
                            // exactly right.
                            //
                            // `.migrationGateDeferredSyncStart`'s own doc already describes this
                            // shape ("even when that session finds nothing to broadcast … where
                            // `migrationStoppedSyncForBroadcast` never gets set either"); it was
                            // armed in the refusal handler and not here.
                            await send(.migrationGateDeferredSyncStart)
                            // A13: and then USE the session for what it was claimed for. With no
                            // background lane on iOS this open IS the delivery window — suppressing
                            // sync without broadcasting would just stall a schedule the user
                            // already confirmed.
                            await migrationManager.advance(.beforeSync)
                        } else {
                            startedSyncThisPass = true
                            // THE DRIVER, on the sync branch too. `visitKind()` above answers only
                            // "may this session sync?"; this is where the engine's actual next step
                            // gets discharged. On a sync visit most steps defer to the post-sync
                            // edge — but `.replan`/`.reevaluate` and `.complete` are answered here, the
                            // wake-ups are re-armed here, and, crucially, this open now LOGS a
                            // verdict whether or not it did anything. A session that did nothing and
                            // said nothing is indistinguishable from a frozen app.
                            await migrationManager.advance(.beforeSync)
                            // TODO: [#1755] T6.8-L1: resolve server selection BEFORE first start so the
                            // automatic race completes while the synchronizer is still idle. Without this
                            // the race finished ~10-20s into the first pass and triggered a switchTo
                            // restart ([WARNING] switchTo during active sync — pass will restart).
                            // Skip during background tasks (matches the .refreshAutomaticServer guard).
                            // mid-session re-selection (post-start) is kept via .refreshAutomaticServer.
                            if state.bgTask == nil {
                                // zcash #1757 split refreshIfEnabled() into findBestServer + applySwitch.
                                // Pre-start the synchronizer is idle, so applySwitch (switchIfIdle) applies
                                // immediately — same intent. findBestServer() returns nil when Automatic is
                                // off / nothing better, so this is a no-op in manual mode.
                                if let best = await autoServerSelection.findBestServer() {
                                    _ = await autoServerSelection.applySwitch(best)
                                }
                            }
                            do {
                                try await sdkSynchronizer.start(true)
                            } catch ZcashError.migrationSyncBlocked {
                                // Same signal as the cold-launch site in `.initializeSDK`: the gate
                                // refusing start() up front IS the send-visit signal — `visitKind()`
                                // classifies from the SCANNED-tip-only `migrationAdvanceStep()` and
                                // can still lag this gate's (`isMigrationSyncBlocked`) ESTIMATED-tip
                                // view right after a no-sync broadcast session. Treat the refusal
                                // like a `.send` visit rather than a `.synchronizerStartFailed` dead
                                // end: run the broadcast session, then fall through unchanged into
                                // the same post-start code below. `.registerForSynchronizersUpdate`
                                // subscribes the gate stream, and `.migrationSyncGateChanged(false)`
                                // resumes with another `.retryStart` once the gate reopens. The
                                // broadcast lane itself reads `useEstimatedTip: true`, so it sees
                                // exactly what the gate saw when it refused.
                                let refusalReason = "start refused — migration gate active; running broadcast session"
                                LoggerProxy.event("\(MigrationManagerImpl.logTag) \(refusalReason)")
                                await send(.migrationGateDeferredSyncStart)
                                await migrationManager.advance(.beforeSync)
                            }
                        }
                        if state.bgTask != nil {
                            LoggerProxy.event("BGTask synchronizer.start() PASSED")
                        }
                        // THE SPIN CUT (MOB-1466, Lukas 2026-08-07 — 1,297 iterations at ~10.7/s in
                        // one device log, still running when it was captured, and NOT stopping at
                        // background: 816 of those ran with no live trace session, each re-arming a
                        // local notification).
                        //
                        // The cycle, all four links inside this one case:
                        //   1. `visitKind() == .send` (a broadcast is due) -> skip sync start,
                        //   2. `.migrationGateDeferredSyncStart` re-arms `syncDeferredByMigrationGate`,
                        //   3. this line re-registers the subscriptions, and `migrationSyncGateFeed()`
                        //      SEEDS every fresh subscription with a live gate read (audit
                        //      2026-08-03 #9) — so a re-registration emits `false` all by itself,
                        //   4. `.migrationSyncGateChanged(false)` finds `isGenuineChange == false`
                        //      but `shouldResume == true` (step 2 armed it) and sends `.retryStart`,
                        //      which is this case. Back to 1, with no state change anywhere.
                        //
                        // It self-sustains only while `visitKind()` keeps answering `.send`, which
                        // is why nobody saw it before: a broadcast that SUCCEEDS stops answering
                        // `.send` after a turn or two and the loop ends on its own. It took a
                        // broadcast that could never succeed in-session (`migrationBroadcastDuringSync`
                        // + the R0 once-credit refusing a retry) to turn two turns into forever.
                        //
                        // Cutting link 3 is the honest cut: a pass that never touched the
                        // synchronizer has nothing to re-register. The sync branch still registers
                        // (including its gate-refusal catch, whose own doc depends on it), the cold
                        // launch's `.initializeSDK` still registers, and audit #9's seed still
                        // repairs a dropped nudge on every registration that genuinely happens —
                        // this only stops a no-op pass from manufacturing one.
                        if startedSyncThisPass {
                            await send(.initialization(.registerForSynchronizersUpdate))
                        }
                        // Backgrounding cancels the transaction subscriptions (event stream and
                        // `.upToDate` fetch trigger); without re-establishing them here, the first
                        // background/foreground cycle would leave the transaction list refreshing
                        // only via chance one-shot fetches for the rest of the process lifetime.
                        // Re-dispatch is safe: the inner effects replace themselves via
                        // `.cancellable(cancelInFlight: true)`, and the trailing fetch doubles as
                        // the catch-up for anything mined while backgrounded. Deliberately OUTSIDE
                        // the spin cut above: these are transaction streams only — no gate feed, so
                        // no self-seeded emission (link 3) — and a broadcast-only pass still needs
                        // the list observing what its own broadcast creates.
                        await send(.observeTransactions)
                        await send(.refreshAutomaticServer)
                    } catch {
                        if state.bgTask != nil {
                            LoggerProxy.event("BGTask synchronizer.start() failed \(error.toZcashError())")
                        }
                        // Audit 2026-08-03 (#7): subscriptions must SURVIVE a failed start. The
                        // register used to be reachable only through the success path, so a
                        // transient start error left BOTH the sync state stream and the migration
                        // gate feed unsubscribed for the whole foreground — no edges, no gate
                        // emissions, no resume until the next background→foreground round trip.
                        await send(.initialization(.registerForSynchronizersUpdate))
                        await send(.initialization(.synchronizerStartFailed(error.toZcashError())))
                    }
                }

            case .initialization(.registerForSynchronizersUpdate):
                let stateStreamEffect = Effect.publisher {
                    sdkSynchronizer.stateStream()
                        .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                        .map { $0.redacted }
                        .map(Root.Action.synchronizerStateChanged)
                }
                .cancellable(id: state.CancelStateId, cancelInFlight: true)

                // Both migration gate feeds funnel into the SAME action under the SAME cancel id, so
                // they start and stop together. The SDK's own stream re-evaluates the wallet
                // predicate on a ~15 s ticker (and immediately after a broadcast) and dedupes
                // internally; the app-side feed is what a broadcast-failure site nudges when it
                // stopped sync for a broadcast that never reached a successful outcome. The seed
                // read ahead of the stream is what makes a cold start resume a sync stopped by a
                // broadcast in a previous session.
                let migrationSyncGateEffect = Effect.merge(
                    Effect.concatenate(
                        .run { [sdkSynchronizer] send in
                            await send(.migrationSyncGateChanged(await sdkSynchronizer.isMigrationSyncBlocked()))
                        },
                        Effect.publisher {
                            // No `.dropFirst()` (audit 2026-08-03, #19): the subscribe-time replay
                            // can be the ONLY carrier of an edge that flipped between the explicit
                            // seed read above and this subscription landing — dropping it lost that
                            // edge for the whole cycle. The `.migrationSyncGateChanged` handler
                            // dedupes (`isGenuineChange`/`shouldResume`), so the duplicate a kept
                            // seed usually produces is a no-op, never a double resume.
                            sdkSynchronizer.migrationSyncBlockedStream()
                                .map(Root.Action.migrationSyncGateChanged)
                        }
                    ),
                    .run { [migrationManager] send in
                        for await isBlocked in migrationManager.migrationSyncGateFeed() {
                            await send(.migrationSyncGateChanged(isBlocked))
                        }
                    }
                )
                .cancellable(id: state.migrationSyncGateCancelId, cancelInFlight: true)

                if state.bgTask != nil {
                    return .merge(stateStreamEffect, migrationSyncGateEffect)
                } else {
                    return .merge(
                        stateStreamEffect,
                        migrationSyncGateEffect,
                        .send(.home(.smartBanner(.evaluatePriority1)))
                    )
                }

            case .initialization(.checkWalletConfig):
                return .run { send in
                    let walletConfig = await walletConfigProvider.load()
                    await send(.walletConfigLoaded(walletConfig))
                }
                .cancellable(id: state.WalletConfigCancelId, cancelInFlight: true)

            case .walletConfigLoaded(let walletConfig):
                if walletConfig == WalletConfig.initial {
                    return .send(.initialization(.initialSetups))
                } else {
                    return .send(.initialization(.walletConfigChanged(walletConfig)))
                }
                
            case .initialization(.walletConfigChanged(let walletConfig)):
                return .concatenate(
                    .send(.updateStateAfterConfigUpdate(walletConfig)),
                    .send(.initialization(.initialSetups))
                )
                
            case .initialization(.initialSetups):
                // macOS without a Secure Enclave (pre-T2 Intel): the seed can't be stored securely and
                // there's no plaintext fallback, so create/restore would hard-error. Surface a clear info
                // screen instead. Always true on iOS and on Secure-Enclave Macs → no behavior change there.
                if !walletStorage.isSecureStorageAvailable() {
                    state.osStatusErrorState.secureEnclaveUnavailable = true
                    return .send(.destination(.updateDestination(.osStatusError)))
                }
                if !diskSpaceChecker.hasEnoughFreeSpaceForSync() {
                    state.destinationState.preNotEnoughFreeSpaceDestination = state.destinationState.internalDestination
                    return .send(.destination(.updateDestination(.notEnoughFreeSpace)))
                } else if let preNotEnoughFreeSpaceDestination = state.destinationState.preNotEnoughFreeSpaceDestination {
                    state.destinationState.internalDestination = preNotEnoughFreeSpaceDestination
                    state.destinationState.preNotEnoughFreeSpaceDestination = nil
                }
                // TODO: [#524] finish all the wallet events according to definition, https://github.com/Electric-Coin-Company/zashi-ios/issues/524
                LoggerProxy.event(".appDelegate(.didFinishLaunching)")
                /// We need to fetch data from keychain, in order to be 100% sure the keychain can be read we delay the check a bit.
                /// macOS: first transparently migrate any legacy plaintext seed into the Secure Enclave, so an
                /// un-migrated wallet isn't seen as "keysMissing" and sent to onboarding (no-op on iOS / once done).
                return .run { send in
                    try? await walletStorage.migrateToSecureEnclave()
                    await send(.initialization(.checkWalletInitialization))
                }

                /// Evaluate the wallet's state based on keychain keys and database files presence
            case .initialization(.checkWalletInitialization):
                let walletState = Root.walletInitializationState(
                    databaseFiles: databaseFiles,
                    walletStorage: walletStorage,
                    zcashNetwork: zcashSDKEnvironment.network()
                )
                return .send(.initialization(.respondToWalletInitializationState(walletState)))

                /// Respond to all possible states of the wallet and initiate appropriate side effects including errors handling
            case .initialization(.respondToWalletInitializationState(let walletState)):
                switch walletState {
                case .osStatus(let osStatus):
                    state.osStatusErrorState.osStatus = osStatus
                    return .send(.destination(.updateDestination(.osStatusError)))
                case .failed:
                    state.appInitializationState = .failed
                    state.alert = AlertState.walletStateFailed(walletState)
                    return .none
                case .keysMissing:
                    state.appInitializationState = .keysMissing
                    return .send(.destination(.updateDestination(.onboarding)))
                case .filesMissing:
                    state.appInitializationState = .filesMissing
                    state.isRestoringWallet = true
                    userDefaults.setValue(true, Constants.udIsRestoringWallet)
                    state.$walletStatus.withLock { $0 = .restoring }
                    return .concatenate(
                        .send(.initialization(.initializeSDK(.restoreWallet))),
                        .send(.initialization(.checkBackupPhraseValidation))
                    )
                case .initialized:
                    if let isRestoringWallet = userDefaults.objectForKey(Constants.udIsRestoringWallet) as? Bool, isRestoringWallet {
                        state.isRestoringWallet = true
                        state.$walletStatus.withLock { $0 = .restoring }
                        return .concatenate(
                            .send(.initialization(.initializeSDK(.restoreWallet))),
                            .send(.initialization(.checkBackupPhraseValidation))
                        )
                    } else if let isResyncingWallet = userDefaults.objectForKey(Constants.udIsResyncingWallet) as? Bool, isResyncingWallet {
                        state.isRestoringWallet = true
                        state.$walletStatus.withLock { $0 = .resyncing }
                        return .concatenate(
                            .send(.initialization(.initializeSDK(.restoreWallet))),
                            .send(.initialization(.checkBackupPhraseValidation))
                        )
                    }
                    return .concatenate(
                        .send(.initialization(.initializeSDK(.existingWallet))),
                        .send(.initialization(.checkBackupPhraseValidation))
                    )
                case .uninitialized:
                    state.appInitializationState = .uninitialized
                    return .run { send in
                        try await mainQueue.sleep(for: .seconds(0.5))
                        await send(.destination(.updateDestination(.onboarding)))
                    }
                    .cancellable(id: state.CancelId, cancelInFlight: true)
                }
                
                /// Stored wallet is present, database files may or may not be present, trying to initialize app state variables and environments.
                /// When initialization succeeds user is taken to the home screen.
            case .initialization(.initializeSDK(let walletMode)):
                // First prepare wins: a foreground transition (or any other re-entry into the
                // initialization chain) while `prepareWith` is still in flight must not start a
                // second concurrent prepare — see `isInitializingSDK`. Dropping the action is
                // safe: the in-flight effect always ends in one of the terminal actions that
                // clear the latch and drive navigation themselves.
                guard !state.isInitializingSDK else { return .none }
                state.isInitializingSDK = true
                // Seed handling (docs/macos/KEYCHAIN_SE_HARDENING.md): the macOS seed is
                // Secure-Enclave-wrapped, so decrypting it prompts. The SDK's `prepareWith` takes
                // an OPTIONAL seed — once the wallet exists in `data.db` we prepare WITHOUT it (no
                // prompt on normal launches). The seed is decrypted only on FIRST init (the user
                // just supplied it) and reused for the seed-derived keys below and for the heal
                // path; on the nil-seed fast path it is decrypted lazily, only if the SDK actually
                // asks for it back (`.seedRequired`, below).
                let dbFilesPresent = databaseFiles.areDbFilesPresentFor(zcashSDKEnvironment.network())
                return .run { send in
                    do {
                        var seedBytes: [UInt8]?
                        let birthday: BlockHeight
                        if dbFilesPresent {
                            seedBytes = nil
                            birthday = (try? walletStorage.exportWalletMetadata().birthday?.value())
                                ?? zcashSDKEnvironment.latestCheckpoint()
                        } else {
                            let storedWallet: StoredWallet
                            do {
                                storedWallet = try await walletStorage.exportWallet(nil)
                            } catch {
                                await send(.destination(.updateDestination(.osStatusError)))
                                return
                            }
                            try mnemonic.isValid(storedWallet.seedPhrase.value())
                            seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                            birthday = storedWallet.birthday?.value() ?? zcashSDKEnvironment.latestCheckpoint()
                        }

                        // [#1755] The SDK derives the init flow from the birthday: a brand-new wallet
                        // passes nil (the SDK picks a reorg-safe recent height), restore/existing pass
                        // the stored birthday. `walletMode` is no longer handed to the SDK.
                        var result: Initializer.InitializationResult
                        do {
                            result = try await sdkSynchronizer.prepareWith(
                                seedBytes,
                                walletMode == .newWallet ? nil : birthday,
                                String(localizable: .accountsZashi),
                                String(localizable: .accountsZashi).lowercased()
                            )
                        } catch ZcashError.initializerSeedMismatch {
                            // The SDK now runs this same integrity check inside
                            // Initializer.initialize and throws instead of returning, for
                            // exactly the case reconcileWalletDatabaseWithSeed below already
                            // exists to heal. Map the throw onto .seedNotRelevant so that
                            // knownStale: true heal still runs unchanged.
                            //
                            // Safe unconditionally: wipe() below leaves no accounts in the
                            // database, so the re-prepare that follows cannot hit this
                            // mismatch again. And prepare() throws before the synchronizer
                            // ever leaves .unprepared (SDKSynchronizer.prepare only advances
                            // status once initialize() returns successfully), so that
                            // re-prepare isn't blocked by prepare's own
                            // `guard status == .unprepared` early-return either.
                            result = .seedNotRelevant
                        }

                        // macOS SE-hardening fast path (docs/macos/KEYCHAIN_SE_HARDENING.md):
                        // `.seedRequired` here means the nil-seed prepare above genuinely needed
                        // the seed. Decrypt once — the one prompt this launch could not avoid —
                        // and retry with it, rather than surfacing `synchronizerNotPrepared` for
                        // a wallet that is actually fine. Unreachable on the always-seed branch
                        // above (`seedBytes` is already non-nil there), so this only ever closes
                        // the fast path's own gap.
                        if result == .seedRequired, seedBytes == nil {
                            let storedWallet: StoredWallet
                            do {
                                storedWallet = try await walletStorage.exportWallet(nil)
                            } catch {
                                await send(.destination(.updateDestination(.osStatusError)))
                                return
                            }
                            try mnemonic.isValid(storedWallet.seedPhrase.value())
                            seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                            do {
                                result = try await sdkSynchronizer.prepareWith(
                                    seedBytes,
                                    walletMode == .newWallet ? nil : birthday,
                                    String(localizable: .accountsZashi),
                                    String(localizable: .accountsZashi).lowercased()
                                )
                            } catch ZcashError.initializerSeedMismatch {
                                result = .seedNotRelevant
                            }
                        }

                        let healed: Bool
                        switch result {
                        case .seedRequired:
                            throw ZcashError.synchronizerNotPrepared
                        case .seedNotRelevant, .success:
                            if let seedBytes {
                                healed = try await Root.reconcileWalletDatabaseWithSeed(
                                    knownStale: result == .seedNotRelevant,
                                    seedBytes: seedBytes,
                                    isSeedRelevant: { try await sdkSynchronizer.isSeedRelevantToAnyDerivedAccount($0) },
                                    hasSeedDerivedAccount: {
                                        let accounts = try await sdkSynchronizer.walletAccounts()
                                        return accounts.contains { $0.zip32AccountIndex != nil }
                                    },
                                    clearDeviceScopedState: {
                                        Root.clearDeviceScopedWalletState(
                                            userDefaults: userDefaults,
                                            flexaHandler: flexaHandler,
                                            userStoredPreferences: userStoredPreferences,
                                            readTransactionsStorage: readTransactionsStorage
                                        )
                                    },
                                    wipe: {
                                        guard let wipePublisher = sdkSynchronizer.wipe() else {
                                            throw Root.WalletDatabaseHealError.wipeUnavailable
                                        }
                                        for try await _ in wipePublisher.values { }
                                    },
                                    reprepare: {
                                        let reprepareResult = try await sdkSynchronizer.prepareWith(
                                            seedBytes,
                                            birthday,
                                            String(localizable: .accountsZashi),
                                            String(localizable: .accountsZashi).lowercased()
                                        )
                                        guard reprepareResult == .success else {
                                            throw ZcashError.synchronizerNotPrepared
                                        }
                                    }
                                )
                            } else {
                                // macOS SE-hardening fast path: no seed was ever decrypted for
                                // this launch (ordinary launch, `.success` on the first nil-seed
                                // prepare) — the staleness check above needs a seed to check
                                // AGAINST, so there is nothing it can do here, and nothing to
                                // heal. Forcing a decrypt just to run it would reintroduce the
                                // every-launch prompt the fast path exists to avoid.
                                healed = false
                            }
                        }
                        if healed {
                            await send(.initialization(.staleWalletDatabaseHealed))
                        }

                        let walletAccounts = try await sdkSynchronizer.walletAccounts()
                        await send(.initialization(.loadedWalletAccounts(walletAccounts)))

                        // First init only (we still hold the seed): derive the seed-derived metadata
                        // encryption keys HERE, reusing `seedBytes`, so the async
                        // resolveMetadataEncryptionKeys below finds them present and never re-decrypts
                        // the Secure-Enclave seed. Together with WalletStorage's primed-seed reuse,
                        // restore/create fires ZERO seed prompts (docs/macos/KEYCHAIN_SE_HARDENING.md).
                        // Existing-wallet launches keep seedBytes == nil, so the standard
                        // resolveMetadataEncryptionKeys recovery path is unchanged.
                        if let seedBytes {
                            for account in walletAccounts
                            where (try? walletStorage.exportUserMetadataEncryptionKeys(account.account)) == nil {
                                do {
                                    var keys = UserMetadataEncryptionKeys.empty
                                    try keys.cacheFor(
                                        seed: seedBytes,
                                        account: account.account,
                                        network: zcashSDKEnvironment.network().networkType
                                    )
                                    try walletStorage.importUserMetadataEncryptionKeys(keys, account.account)
                                } catch {
                                    LoggerProxy.event("first-init metadata key derivation failed for '\(account.account.name ?? "?")': \(error)")
                                }
                            }
                        }

                        // Dispatched only now that `.loadedWalletAccounts` has selected an account:
                        // `.fetchTransactionsForTheSelectedAccount` silently no-ops without one, and on
                        // a cold start `selectedWalletAccount` (in-memory) is nil until that selection —
                        // dispatching any earlier is a guaranteed no-op, leaving the list empty until
                        // the post-gate `.observeTransactions` fetch finally runs. Fire-and-forget on
                        // purpose: the fetch races ahead on the still-quiet synchronizer while the
                        // migration gate below does its network-bound work.
                        await send(.fetchTransactionsForTheSelectedAccount)
                        await send(.resolveMetadataEncryptionKeys)
                        await send(.loadUserMetadata)

                        // Same session separation as the foreground path above — a launch that
                        // lands in a due broadcast window must not sync either. See
                        // `MigrationVisit`.
                        if await migrationManager.visitKind() == .send {
                            LoggerProxy.event("\(MigrationManagerImpl.logTag) skipping sync start on launch — broadcast session")
                            // I5, N4's TWIN — live until 2026-08-02 and identical in shape to the
                            // bug that froze a foreground session for six minutes. `.retryStart`
                            // got its `.migrationGateDeferredSyncStart` on 08-01; THIS site, the
                            // cold-launch one, did not, so a launch that landed in a due
                            // broadcast window suppressed sync and armed nothing to bring it
                            // back: `syncDeferredByMigrationGate` stayed false, and
                            // `stopSyncBeforeMigrationBroadcast()` early-returned on
                            // `guard isSyncing()` (correctly — there was no sync to stop), so
                            // `migrationStoppedSyncForBroadcast` stayed false too. When the
                            // post-broadcast buffer cleared, `.migrationSyncGateChanged(false)`
                            // computed `shouldResume = !isBlocked && (false || false)` and
                            // returned without a `.retryStart`. Sync never resumed for the whole
                            // launch — no polling, no sync-complete edge, no driver call at the
                            // edge, no reconcile, no pokes. The rule that closes the whole class:
                            // A SESSION THAT SUPPRESSES SYNC ALWAYS ARMS ITS OWN RESUME.
                            await send(.migrationGateDeferredSyncStart)
                            await migrationManager.advance(.beforeSync)
                        } else {
                            await migrationManager.advance(.beforeSync)
                            // TODO: [#1755] T6.8-L1: resolve server selection BEFORE first start.
                            // The automatic race completes here while the synchronizer is still idle;
                            // previously it ran post-start and triggered a switchTo restart ~10-20s
                            // into the first pass ([WARNING] switchTo during active sync — pass will
                            // restart), wasting ~50s on iPad A10 / ~5-10s on iPhone.
                            // evaluateBestOf is bounded by evaluationTimeoutSeconds=5.0 (existing
                            // constant in AutoServerSelectionConstants) so no new timeout is needed.
                            // zcash #1757 split refreshIfEnabled() into findBestServer + applySwitch.
                            // findBestServer() returns nil when Automatic is off, so this stays a
                            // no-op in manual mode; pre-start the synchronizer is idle so applySwitch
                            // (switchIfIdle) applies immediately — same intent as before.
                            if let best = await autoServerSelection.findBestServer() {
                                _ = await autoServerSelection.applySwitch(best)
                            }
                            do {
                                try await sdkSynchronizer.start(false)
                            } catch ZcashError.migrationSyncBlocked {
                                // The gate refusing start() up front IS the send-visit signal:
                                // `visitKind()` classifies from `migrationAdvanceStep()`, which
                                // reflects the SCANNED tip, while this gate
                                // (`isMigrationSyncBlocked`) reads the ESTIMATED tip — so a
                                // launch right after a no-sync broadcast session can see
                                // `visitKind() == .sync` here yet still get refused. Treat the
                                // refusal exactly like a `.send` visit rather than a fatal
                                // `initializationFailed` (which has no retry action): run the
                                // broadcast session, then fall through unchanged into the same
                                // post-start code below. `.registerForSynchronizersUpdate`
                                // (reached via `.initializationSuccessfullyDone`) subscribes the
                                // gate stream, and `.migrationSyncGateChanged(false)` resumes
                                // with `.retryStart` once the gate reopens — see that case for
                                // the resume. The broadcast lane itself reads
                                // `useEstimatedTip: true`, so it sees exactly what the gate saw
                                // when it refused.
                                let refusalReason = "start refused — migration gate active; treating launch as broadcast session"
                                LoggerProxy.event("\(MigrationManagerImpl.logTag) \(refusalReason)")
                                await send(.migrationGateDeferredSyncStart)
                                await migrationManager.advance(.beforeSync)
                            }
                        }

                        var selectedAccount: WalletAccount?

                        for account in walletAccounts {
                            if account.vendor == .zcash {
                                selectedAccount = account
                            }
                        }

                        exchangeRate.refreshExchangeRateUSD()

                        // Address-book keys are seed-derived — derive only when we actually hold the
                        // seed (first init) and they're missing. On normal launches `seedBytes` is nil
                        // and they're already cached, so this is skipped (no prompt).
                        if let account = selectedAccount, let seedBytes {
                            let addressBookEncryptionKeys = try? walletStorage.exportAddressBookEncryptionKeys()
                            if addressBookEncryptionKeys == nil {
                                do {
                                    var keys = AddressBookEncryptionKeys.empty
                                    try keys.cacheFor(
                                        seed: seedBytes,
                                        account: account.account,
                                        network: zcashSDKEnvironment.network().networkType
                                    )
                                    try walletStorage.importAddressBookEncryptionKeys(keys)
                                } catch {
                                    // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                                }
                            }

                            await send(.initialization(.initializationSuccessfullyDone))
                        } else {
                            await send(.initialization(.initializationSuccessfullyDone))
                        }
                    } catch Root.WalletDatabaseHealError.reprepareFailed {
                        // The stale database was already wiped before re-prepare failed, so
                        // there is no database left to leave the user staring at a dead-end
                        // `initializationFailed` alert for (that only recovers on relaunch).
                        // Recompute wallet-initialization state in-session instead: with the
                        // database gone this resolves to `.filesMissing`, which re-enters the
                        // existing restore path. The latch must drop first or the re-entry's
                        // own `.initializeSDK` would be swallowed by the single-flight guard.
                        await send(.initialization(.initializeSDKFinished))
                        await send(.initialization(.checkWalletInitialization))
                    } catch {
                        await send(.initialization(.initializationFailed(error.toZcashError())))
                    }
                }

            case .initialization(.staleWalletDatabaseHealed):
                state.isRestoringWallet = true
                userDefaults.setValue(true, Constants.udIsRestoringWallet)
                state.$walletStatus.withLock { $0 = .restoring }
                state.isStaleWalletHealedAlertPending = true
                // Covers the third transition point: the destination may have already settled
                // on `.home` before this heal signal arrives (e.g. the new-wallet cascade), in
                // which case neither of the other two hooks (`updateDestination` / the
                // `.phraseDisplay`/`.onboarding` bypass arm) will ever fire again to deliver it.
                if state.destinationState.destination == .home {
                    return presentStaleWalletHealedAlertEffect(cancelId: state.staleWalletHealedAlertCancelId)
                }
                return .none

            case .initialization(.presentStaleWalletHealedAlert):
                // Re-check the destination: the 0.5s wait isn't cancelled by leaving `.home`
                // (only re-entering `.home` reschedules this effect), so a deep link or other
                // navigation during the window must not present the notice over whatever screen
                // is showing now. Leave the flag set so a later return to `.home` re-fires the
                // hook and the notice still gets delivered.
                guard state.isStaleWalletHealedAlertPending, state.destinationState.destination == .home else {
                    return .none
                }
                state.isStaleWalletHealedAlertPending = false
                state.alert = AlertState.staleWalletDatabaseHealed()
                return .none

            case .initialization(.initializeSDKFinished):
                state.isInitializingSDK = false
                return .none

            case .initialization(.initializationSuccessfullyDone):
                state.isInitializingSDK = false
                // I4's replay machinery lived here and is GONE with the deeplink that needed it.
                // A latched tap had to be re-applied at this exact point — the one place where "the
                // app is ready" is unambiguously true — so a cold entry would reach the same screen
                // a warm one did. Now both entries reach HOME, which a cold launch was already
                // going to do, so there is nothing to defer and nothing to replay. Entry parity
                // stopped being maintained and became structural.
                return .merge(
                    .send(.initialization(.registerForSynchronizersUpdate)),
                    // Audit 2026-08-03 (#6): the launch-time sweep the snapshot docs always named
                    // but nothing implemented. A provisional network snapshot formed at the Tor
                    // sheet and abandoned (flow closed, app killed before commit) otherwise
                    // outlived every cleaner: auto-server selection stayed pinned to that run's
                    // provider family indefinitely, and a later broadcast could REUSE the stale
                    // endpoint/Tor choice. The abandoned-cleaner's own engine-state guard keeps a
                    // committed run's snapshot untouched.
                    .run { [migrationManager, selected = state.selectedWalletAccount?.id, accounts = state.walletAccounts] _ in
                        for accountUUID in MigrationDerivations.candidateAccountUUIDs(
                            selectedAccountUUID: selected,
                            walletAccounts: accounts
                        ) {
                            await migrationManager.clearAbandonedNetworkSnapshot(accountUUID)
                        }
                    },
                    .publisher {
                        autolockHandler.batteryStatePublisher()
                            .map { _ in Root.Action.batteryStateChanged }
                    }
                    .cancellable(id: state.CancelBatteryStateId, cancelInFlight: true),
                    .send(.batteryStateChanged),
                    .send(.observeTransactions),
                    .send(.observeShieldingProcessor),
                    .send(.observeTorInit),
                    .send(.refreshAutomaticServer),
                    // MOB-1466: the OTHER start/restart site — a completed launch is just as much
                    // "the app is now open" as a foreground re-entry is. See `willEnterForeground`'s
                    // identical call for the "the open breaks the loop's sleep" rationale.
                    migrationTickLoopEffect(state: state)
                )
                
            case .initialization(.loadedWalletAccounts(let walletAccounts)):
                state.$walletAccounts.withLock { $0 = walletAccounts }
                if state.selectedWalletAccount == nil {
                    for account in walletAccounts {
                        if account.vendor == .zcash {
                            state.$selectedWalletAccount.withLock { $0 = account }
                            state.$zashiWalletAccount.withLock { $0 = account }
                            break
                        }
                    }
                }
                return .merge(
                    .send(.loadContacts),
                    .send(.loadUserMetadata),
                    .send(.loadSwapAPIAccess),
                    // MOB-1466 (Lukas's ruling, 2026-08-09): THE MOMENT the banner has been waiting
                    // for. Selecting the account above is what makes the migration question
                    // answerable, and `SmartBanner.evaluatePriority1` now refuses to walk before it
                    // (see that arm for the whole failure). The kick in
                    // `.registerForSynchronizersUpdate` still serves every FOREGROUND pass, where the
                    // account is already loaded; this is the cold-start counterpart, and it is the
                    // same ordering discipline `.fetchTransactionsForTheSelectedAccount` above already
                    // follows for the same reason — that call's own comment records this exact hazard
                    // ("on a cold start `selectedWalletAccount` (in-memory) is nil until that
                    // selection"). The banner's ladder simply never got the same treatment.
                    //
                    // Sent unconditionally: a duplicate walk is harmless (the ladder is idempotent —
                    // it re-reads and re-seats the same occupant), while a missed one costs the whole
                    // launch, which is precisely the bug.
                    .send(.home(.smartBanner(.evaluatePriority1)))
                )

            case .resolveMetadataEncryptionKeys:
                return .run { [walletAccounts = state.walletAccounts] send in
                    // Decrypt the seed only if some account is actually missing its metadata keys
                    // (promptless otherwise — docs/macos/KEYCHAIN_SE_HARDENING.md). The keys are
                    // seed-derived, so on normal launches they're already cached and this never decrypts.
                    let accountsMissingKeys = walletAccounts.filter {
                        (try? walletStorage.exportUserMetadataEncryptionKeys($0.account)) == nil
                    }
                    guard !accountsMissingKeys.isEmpty else { return }

                    guard
                        let storedWallet = try? await walletStorage.exportWallet(nil),
                        let seedBytes = try? mnemonic.toSeed(storedWallet.seedPhrase.value())
                    else { return }

                    for account in accountsMissingKeys {
                        do {
                            var keys = UserMetadataEncryptionKeys.empty
                            try keys.cacheFor(
                                seed: seedBytes,
                                account: account.account,
                                network: zcashSDKEnvironment.network().networkType
                            )
                            try walletStorage.importUserMetadataEncryptionKeys(keys, account.account)
                            await send(.loadUserMetadata)
                        } catch {
                            LoggerProxy.event("resolveMetadataEncryptionKeys: failed to derive metadata keys for account '\(account.account.name ?? "?")': \(error)")
                        }
                    }
                }
                
            case .initialization(.checkBackupPhraseValidation):
                // Existence check only (promptless) — do NOT decrypt the seed here.
                guard (try? walletStorage.areKeysPresent()) == true else {
                    return .send(.destination(.updateDestination(.osStatusError)))
                }

                state.appInitializationState = .initialized
                let isAtDeeplinkWarningScreen = state.destinationState.destination == .deeplinkWarning

                return .run { send in
#if !os(macOS)
                    // iOS-only launch-time desync check ([#1024]): the keychain seed reads without a
                    // prompt here, so re-confirm it still matches the wallet DB and warn if it drifted.
                    // Only a definitive `false` warns; any error defaults to relevant so a transient rust
                    // hiccup never falsely locks a valid wallet, and hardware-only wallets are skipped by
                    // `try?`. Intentionally NOT done on macOS: the seed is Secure-Enclave-wrapped, so this
                    // would prompt on EVERY launch, and the preventive guard at restore (`resolveRestore`,
                    // which uses the freshly-typed seed — no decrypt) already prevents the desync at its
                    // source. Re-checking every launch buys nothing there but a biometric.
                    if databaseFiles.areDbFilesPresentFor(zcashSDKEnvironment.network()),
                       let storedWallet = try? await walletStorage.exportWallet(nil),
                       let seedBytes = try? mnemonic.toSeed(storedWallet.seedPhrase.value()) {
                        let relevant = (try? await sdkSynchronizer.isSeedRelevantToAnyDerivedAccount(seedBytes)) ?? true
                        if !relevant {
                            await send(.initialization(.seedValidationResult(false)))
                        }
                    }
#endif

                    // Delay the splash overlay dismissal
                    try await mainQueue.sleep(for: .seconds(0.5))
                    if !isAtDeeplinkWarningScreen {
                        await send(.destination(.updateDestination(Root.DestinationState.Destination.home)))
                    }
                }
                .cancellable(id: state.CancelId, cancelInFlight: true)
                
            case .osStatusError(.startOverTapped):
                // macOS OSStatusError screen's "Reset Zodl" (MOB-1485): confirm before wiping —
                // the alert's destructive button runs the standard resetZashi flow.
                state.alert = AlertState.wipeRequest()
                return .none

            case .initialization(.resetZashiRequest(let areMetadataPreserved)):
                state.areMetadataPreserved = areMetadataPreserved
                return .send(.initialization(.resetZashi))
                
            case .initialization(.resetZashiRequestCanceled):
                state.alert = nil
                for (id, element) in zip(state.settingsState.path.ids, state.settingsState.path) {
                    if element.is(\.resetZashi) {
                        return .send(.settings(.path(.element(id: id, action: .resetZashi(.deleteCanceled)))))
                    }
                }
                return .none

            case .initialization(.resetZashi):
                guard let wipePublisher = sdkSynchronizer.wipe() else {
                    return .send(.resetZashiSDKFailed)
                }
                return .merge(
                    // [#1755] Return the SmartBanner to its initial state at the START of the wipe so a
                    // stale promo banner (e.g. currency conversion, priority8) doesn't linger through
                    // reset → restore. iPhone hides Home behind the welcome screen so it's never seen;
                    // macOS keeps Home mounted in the split view, so without this the old banner stays
                    // visible until the restoring banner (priority3) finally overrides it.
                    .send(.home(.smartBanner(.closeAndCleanupBanner))),
                    .publisher {
                        wipePublisher
                            .replaceEmpty(with: Void())
                            .map { _ in return Root.Action.resetZashiSDKSucceeded }
                            .replaceError(with: Root.Action.resetZashiSDKFailed)
                            .receive(on: mainQueue)
                    }
                    .cancellable(id: state.SynchronizerCancelId, cancelInFlight: true)
                )

            case .resetZashiSDKSucceeded:
                state.splashAppeared = true
                state.isRestoringWallet = false
                Root.clearDeviceScopedWalletState(
                    userDefaults: userDefaults,
                    flexaHandler: flexaHandler,
                    userStoredPreferences: userStoredPreferences,
                    readTransactionsStorage: readTransactionsStorage
                )
                if !state.areMetadataPreserved {
                    state.walletAccounts.forEach { account in
                        try? userMetadataProvider.resetAccount(account.account)
                        try? addressBook.resetAccount(account.account)
                        #if VOTING_ENABLED
                        try? votingMetadata.resetAccount(account.account)
                        #endif
                    }
                }
                state.walletAccounts.forEach { account in
                    try? walletStorage.clearEncryptionKeys(account.account)
                }
                state.autoUpdateSwapCandidates.removeAll()
                try? userMetadataProvider.reset()
                #if VOTING_ENABLED
                votingMetadata.reset()
                #endif
                state.$walletStatus.withLock { $0 = .none }
                state.$selectedWalletAccount.withLock { $0 = nil }
                state.$walletAccounts.withLock { $0 = [] }
                state.$zashiWalletAccount.withLock { $0 = nil }
                state.$transactionMemos.withLock { $0 = [:] }
                state.$addressBookContacts.withLock { $0 = .empty }
                state.$transactions.withLock { $0 = [] }
                state.path = nil
                if state.appInitializationState != .keysMissing {
                    state = .initial
                }

                // MOB-1466 (N3, field-caught 2026-08-01): the migration wipe rides this same reset
                // boundary as `clearDeviceScopedWalletState` above, for the identical reason that
                // helper gives for its voting sweep — nothing from the previous owner of this device
                // survives it. Without it, a notification armed by the DELETED wallet fires against
                // a freshly restored one and invites the user into a migration run that is not
                // theirs, backed by persisted state keyed to a wallet that no longer exists.
                //
                // Async, so it cannot ride `clearDeviceScopedWalletState` (a synchronous static);
                // sequenced ahead of `.resetZashiKeychainRequest` so the reset chain continues only
                // once the pokes have actually been withdrawn.
                return .run { [migrationManager] send in
                    await migrationManager.wipeAllMigrationState()
                    await send(.resetZashiKeychainRequest)
                }

            case .resetZashiKeychainRequest:
                return .run { send in
                    do {
                        try walletStorage.resetZashi()
                        await send(.resetZashiFinishProcessing)
                    } catch WalletStorage.KeychainError.unknown(let osStatus) {
                        await send(.resetZashiKeychainFailed(osStatus))
                    }
                }

            case .resetZashiFinishProcessing:
                do {
                    let areKeysPresent = try walletStorage.areKeysPresent()
                    if areKeysPresent {
                        return .send(.resetZashiKeychainFailedWithCorruptedData("Keychain keys are still present"))
                    }
                } catch WalletStorage.WalletStorageError.alreadyImported {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("alreadyImported"))
                } catch WalletStorage.WalletStorageError.uninitializedAddressBookEncryptionKeys {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("uninitializedAddressBookEncryptionKeys"))
                } catch WalletStorage.WalletStorageError.storageError(let error) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("storageError, \(error.localizedDescription)"))
                } catch WalletStorage.WalletStorageError.unsupportedVersion(let version) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("unsupportedVersion \(version)"))
                } catch WalletStorage.WalletStorageError.unsupportedLanguage(let language) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("unsupportedLanguage, \(language)"))
                } catch WalletStorage.KeychainError.decoding {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("decoding"))
                } catch WalletStorage.KeychainError.duplicate {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("duplicate"))
                } catch WalletStorage.KeychainError.encoding {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("encoding"))
                } catch WalletStorage.KeychainError.noDataFound {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("noDataFound"))
                } catch WalletStorage.KeychainError.unknown(let osStatus) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("unknown, OSStatus \(osStatus)"))
                } catch WalletStorage.WalletStorageError.uninitializedWallet {
                    // this is valid state and what we expect
                } catch {
                    return .send(.resetZashiKeychainFailedWithCorruptedData(error.localizedDescription))
                }

                return .concatenate(
                    .cancel(id: state.SynchronizerCancelId),
                    .send(.initialization(.checkWalletInitialization))
                )

            case .resetZashiKeychainFailedWithCorruptedData(let errMsg):
                for element in state.settingsState.path {
                    if case .resetZashi(var resetZashiState) = element {
                        resetZashiState.isProcessing = false
                        break
                    }
                }
                state.alert = AlertState.wipeKeychainFailed(errMsg)
                return .cancel(id: state.SynchronizerCancelId)

            case .resetZashiKeychainFailed(let osStatus):
                guard state.maxResetZashiAppAttempts == 0 else {
                    state.maxResetZashiAppAttempts -= 1
                    return .send(.resetZashiKeychainRequest)
                }
                state.maxResetZashiAppAttempts = ResetZashiConstants.maxResetZashiAppAttempts
                for element in state.settingsState.path {
                    if case .resetZashi(var resetZashiState) = element {
                        resetZashiState.isProcessing = false
                        break
                    }
                }
                state.alert = AlertState.wipeFailed(osStatus)
                return .cancel(id: state.SynchronizerCancelId)

            case .resetZashiSDKFailed:
                guard state.maxResetZashiSDKAttempts == 0 else {
                    state.maxResetZashiSDKAttempts -= 1
                    return .concatenate(
                        .cancel(id: state.SynchronizerCancelId),
                        .send(.initialization(.resetZashi))
                    )
                }
                state.maxResetZashiSDKAttempts = ResetZashiConstants.maxResetZashiSDKAttempts
                for element in state.settingsState.path {
                    if case .resetZashi(var resetZashiState) = element {
                        resetZashiState.isProcessing = false
                        break
                    }
                }
                state.alert = AlertState.wipeFailed(Int32.max)
                return .cancel(id: state.SynchronizerCancelId)

            case .phraseDisplay(.finishedTapped), .onboarding(.newWalletSuccessfulyCreated):
                state.destinationState.destination = .home
                // This is the second (synchronous, action-round-trip-free) place the destination
                // can land on `.home` — see `presentStaleWalletHealedAlertEffect` (RootStore.swift).
                if state.isStaleWalletHealedAlertPending {
                    return presentStaleWalletHealedAlertEffect(cancelId: state.staleWalletHealedAlertCancelId)
                }
                return .none

            case .onboarding(.createNewWalletTapped):
                if state.appInitializationState == .keysMissing {
                    state.alert = AlertState.existingWallet()
                    return .none
                } else {
                    return .send(.onboarding(.createNewWalletRequested))
                }

            case .initialization(.restoreExistingWallet):
                return .run { send in
                    await send(.onboarding(.dismissDestination))
                    try await mainQueue.sleep(for: .seconds(1))
                    await send(.onboarding(.importExistingWallet))
                }

            case .initialization(.seedValidationResult(let validSeed)):
                if !validSeed {
                    state.alert = AlertState.differentSeed()
                }
                return .none

            case .updateStateAfterConfigUpdate(let walletConfig):
                state.walletConfig = walletConfig
                return .none

            case .initialization(.initializationFailed(let error)):
                state.isInitializingSDK = false
                state.appInitializationState = .failed
                state.alert = AlertState.initializationFailed(error)
                return .none

            default:
                return .none
            }
        }
    }
    
    private func checkUnavailableService(_ error: Error) -> Bool {
        switch error {
        case ZcashError.serviceGetInfoFailed(.timeOut),
            ZcashError.serviceLatestBlockFailed(.timeOut),
            ZcashError.serviceLatestBlockHeightFailed(.timeOut),
            ZcashError.serviceBlockRangeFailed(.timeOut),
            ZcashError.serviceSubmitFailed(.timeOut),
            ZcashError.serviceFetchTransactionFailed(.timeOut),
            ZcashError.serviceFetchUTXOsFailed(.timeOut),
            ZcashError.serviceBlockStreamFailed(.timeOut),
            ZcashError.serviceSubtreeRootsStreamFailed(.timeOut):
            return true
        default: return false
        }
    }

    /// Presents the one-time Ironwood announcement screen once the device hasn't acknowledged
    /// it yet, Ironwood is active on chain, and it is safe to take the screen over. Called from
    /// both `.synchronizerStateChanged` (cold start and the tail of a restore) and
    /// `.appDelegate(.willEnterForeground)` (returning to the foreground, where the tip is
    /// already known in memory from before backgrounding) — together the two cover every moment
    /// the tip or the safety gate can newly satisfy the predicate.
    ///
    /// Each guard below is load-bearing and deliberately ordered:
    /// 1. the in-memory per-session latch short-circuits every call once the gate has already
    ///    "resolved" this session (presented, or found already-acknowledged in the keychain);
    /// 2. the tip/activation check runs before any keychain access — cheap, and it keeps the
    ///    (overwhelmingly common, pre-activation) path from ever touching the keychain. `tip > 0`
    ///    is a deliberate fail-safe: the chain tip is in-memory only and reads `0` before the
    ///    first successful server round-trip, and an unknown tip must count as "not active" —
    ///    never as a false positive that skips straight past activation;
    /// 3. the keychain read happens at most once per session: as soon as it reports
    ///    already-acknowledged, the latch is set so this guard is never evaluated again;
    /// 4. the safety gate is re-checked on every call and deliberately does NOT set the latch on
    ///    failure, so a blocked attempt (e.g. mid-flow) retries on a later tick instead of being
    ///    silently skipped for the rest of the session.
    func presentIronwoodAnnouncementIfNeeded(state: inout Root.State, tip: BlockHeight) {
        guard !state.ironwoodAnnouncementResolved else { return }
        guard tip > 0, tip >= zcashSDKEnvironment.ironwoodActivationHeight() else { return }
        guard walletStorage.exportIronwoodAnnouncementFlag() != true else {
            state.ironwoodAnnouncementResolved = true
            return
        }
        guard state.canPresentIronwoodAnnouncement else { return }
        state.ironwoodAnnouncementResolved = true
        // Assigned directly rather than sending `.destination(.updateDestination(...))`: the
        // two call sites below have several early-return paths of their own, and merging an
        // effect into all of them would be invasive. The two things `updateDestination` adds
        // over a direct assignment — the deeplink-warning guard and the deferred
        // stale-wallet-healed alert hook — are both no-ops here: `canPresentIronwoodAnnouncement`
        // already requires `destination == .home`, so the deeplink-warning screen can't be in
        // play, and the heal hook only fires when the destination is moving TO `.home`, not away
        // from it. There is precedent for a direct assignment in this same file — see
        // `state.destinationState.destination = .home` in the `.phraseDisplay(.finishedTapped)` /
        // `.onboarding(.newWalletSuccessfulyCreated)` arm above.
        state.destinationState.destination = .ironwoodAnnouncement
    }

    // MARK: - MOB-1466: the foreground migration TICK LOOP

    /// A `privateScheduled` migration run's broadcast opportunities used to come from app-opens
    /// ALONE (`.beforeSync`) — an app left sitting open in the foreground for the ten-plus minutes
    /// between transfer windows advanced nothing on its own, however long it stayed frontmost,
    /// because nothing short of a fresh open ever asked the engine again. This effect closes that
    /// gap: a recurring 30s wake-up (`.migrationTick`, handled above) for exactly as long as the app
    /// stays open and a run exists that could use it.
    ///
    /// SPAWN CONDITION, re-derived fresh at every call site rather than cached in state: Ironwood
    /// must be active AND at least one CANDIDATE account (the identical set
    /// `MigrationStepDriver.advance` itself derives, via the same `MigrationDerivations
    /// .candidateAccountUUIDs`) must be running `.privateScheduled`. An `.immediate`-only wallet has
    /// nothing a tick could ever help with — see `MigrationStepPlan`'s tick column and the mode belt
    /// in `executeBroadcast` — so spawning the loop for one would just be a silent no-op every 30s,
    /// forever, for a wallet that will never have anything for it to do.
    ///
    /// `cancelInFlight: true` on the SAME `migrationTickCancelId` at every start/restart site is
    /// "the open breaks the loop's sleep": both call sites below are lifecycle edges (a fresh
    /// foreground, a just-completed launch) at which resetting the countdown to zero is exactly
    /// right — there is no reason for a wake-up armed several minutes into a PREVIOUS foreground to
    /// fire moments after a new one begins.
    ///
    /// The effect's own body only ever SENDS `.migrationTick` — ticking is all it does. Calling the
    /// driver, deciding whether to keep going, and reacting to what it found are the REDUCER's job
    /// (the `.migrationTick`/`.migrationTickAdvanced` cases above), which is what lets this effect be
    /// cancelled cleanly at any instant without ever leaving an in-flight `advance()` half-handled.
    func migrationTickLoopEffect(state: Root.State) -> Effect<Root.Action> {
        // MOB-1466: THE OFF SWITCH, checked before anything else. `.zero` (set on
        // `Constants.migrationTickInterval`, or injected by a test) means the automatic loop does
        // not exist: no spawn, no timer, no engine reads — while the app-open pokes, a separate
        // lane entirely, keep working (pinned by `zeroIntervalKeepsTheForegroundPokeWorking`).
        guard migrationTickInterval > Swift.Duration.zero else {
            return .none
        }

        // `isIronwoodActivated` gated FIRST, as its own `guard`, deliberately — every OTHER Root
        // lifecycle test in the suite reaches this call site (it runs on every
        // `.initializationSuccessfullyDone`/`.willEnterForeground`), and most of them have no
        // reason to stub `migrationManager` at all. `migrationMode` has no macro-supplied default
        // (unlike `isIronwoodActivated`, which safely defaults `false`), so it traps under
        // `MigrationManagerClient.testValue` when called unstubbed — this guard must therefore
        // short-circuit BEFORE `migrationMode` is ever reached, not merely list both conditions in
        // one `guard a, b` (which still evaluates a `let` computed ahead of it regardless of `a`).
        guard migrationManager.isIronwoodActivated() else {
            return .none
        }

        let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: state.selectedWalletAccount?.id,
            walletAccounts: state.walletAccounts
        )
        // ANY committed run spawns the loop, immediate mode included (G1 fix, field 2026-08-05 —
        // a fresh-commit session sat under "Keep Zodl open" forever): a run's note-PREPARATIONS
        // are engine-paced wallet plumbing in EVERY mode, and the tick lane is what proves and
        // delivers them between opens (AUD-3 F4 exempts preps from the tick's mode belt; D2 sends
        // a proved prep in the same pass). The belt still holds immediate-mode TRANSFERS — pacing
        // those stays the user's own choice, and a live loop does not change it. No stored mode =
        // no committed run = nothing for a tick to help with; the loop also self-stops on
        // `.complete`/`.noRun`.
        let hasCommittedCandidate = accountUUIDs.contains { accountUUID in
            migrationManager.migrationMode(accountUUID) != nil
        }
        guard hasCommittedCandidate else {
            return .none
        }

        return .run { send in
            // The first tick fires 30s from NOW, never at t=0: `clock.timer(interval:)` sleeps a
            // full interval before its first element, and an app-open already just ran its own
            // `.beforeSync`/`.afterSync` pair moments ago (or is about to) — an immediate tick would
            // only ever race that, never add anything.
            for await _ in continuousClock.timer(interval: migrationTickInterval) {
                await send(.migrationTick)
            }
        }
        .cancellable(id: state.migrationTickCancelId, cancelInFlight: true)
    }

    // MARK: - PHASE 7: opening the migration flow from OUTSIDE it

    /// The single entry point for opening (or re-opening) the migration flow. Currently reached
    /// from one Root-side site — the banner tap (notification taps land on Home now, not here) —
    /// but kept as its own helper rather than inlined at the call site: replacing
    /// `migrationCoordFlowState` wholesale must always run the same defensive teardown first, and a
    /// second call site would otherwise risk drifting from it.
    func openMigrationCoordFlow(state: inout Root.State) -> Effect<Root.Action> {
        let cancelEffect = cancelAbandonedKeystoneMigrationRun(state: state)
        state.migrationCoordFlowState = MigrationCoordFlow.State.initial
        state.path = Root.State.Path.migrationCoordFlow
        return cancelEffect
    }

    /// Cancels the engine run a Keystone BATCH ceremony created, when the flow is being torn down
    /// from OUTSIDE while that ceremony is still live.
    ///
    /// The engine creates a Keystone commit's ENTIRE run — preparations and the schedule's transfers
    /// alike — the moment its PCZTs are built (`proposeNoteSplitPCZTs`, called by
    /// `MigrationCommitPipeline.proposeKeystoneBatch`), and always resumes a stored non-terminal run
    /// on the next attempt, ignoring any newer preview. Wiping `migrationCoordFlowState` while
    /// `pendingKeystoneSigning` is live would strand that run: a later re-entry would silently resume
    /// signing the same, by-then-stale PCZTs instead of proposing a fresh preview.
    ///
    /// `pendingKeystoneSigning` is only ever set once the ceremony actually started, so its presence
    /// here means exactly "a ceremony was begun and never resolved". Cancel via
    /// `restartCurrentMigrationStep`, discarding the fresh schedule it returns — the user re-runs the
    /// ceremony from a fresh preview, the same v1 semantics as the in-flow
    /// `.keystoneScanAbandoned` twin.
    ///
    /// Restricted to `.planCommit`: the immediate lane's `createPCZTFromProposal` is engine-external
    /// and created no run, so cancelling for it would at best be a no-op and at worst restart an
    /// unrelated committed run. Read BEFORE the caller resets the state, and cancelled on the run's
    /// RECORDED owner (`pendingKeystoneSigningAccountUUID`) rather than the currently-selected
    /// account, which can have moved on by the time this runs. Fire-and-forget: a failure just leaves
    /// the stray run for the next attempt to encounter and cancel itself.
    func cancelAbandonedKeystoneMigrationRun(state: Root.State) -> Effect<Root.Action> {
        guard case .planCommit? = state.migrationCoordFlowState.pendingKeystoneSigning,
              let accountUUID = state.migrationCoordFlowState.pendingKeystoneSigningAccountUUID
                ?? state.selectedWalletAccount?.id else {
            return .none
        }

        return .run { [sdkSynchronizer] _ in
            _ = try? await sdkSynchronizer.restartCurrentMigrationStep(accountUUID)
        }
    }
}
