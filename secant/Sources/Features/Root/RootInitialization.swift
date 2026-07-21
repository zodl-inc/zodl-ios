//
//  RootInitialization.swift
//  Zashi
//
//  Created by Lukáš Korba on 01.12.2022.
//

import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import BackgroundTasks
@preconcurrency import ZcashLightClientKit

/// Wraps a `BGProcessingTask` for the migration BG session decision tree (MOB-1467). A bare
/// `BGProcessingTask` cannot be instantiated in unit tests, so the AppDelegate-facing
/// `.migrationBackgroundTask(BGProcessingTask)` action is immediately wrapped into this handle
/// and forwarded to `.migrationBackgroundSession`, the action the reducer's tree — and every
/// `RootMigrationBackgroundTests` case — actually drives. `rawTask` is `nil` in tests (spy
/// handles); `complete` is always a real, observable closure (`LockIsolated` spy in tests, real
/// `task.setTaskCompleted(success:)` in production via the AppDelegate-side `live` initializer).
/// `@unchecked Sendable`: `BGProcessingTask` (a system framework type, `@preconcurrency`-imported
/// above) is safe to hand across the effect boundary here the same way the existing
/// `power_wifi_sync`/`scheduler` tasks already are (`Root.State.bgTask`, `AppDelegate`'s
/// `task.expirationHandler`) — it is only ever read or completed, never mutated concurrently.
struct MigrationBGSessionHandle: @unchecked Sendable {
    let rawTask: BGProcessingTask?
    let complete: @Sendable (Bool) -> Void

    init(rawTask: BGProcessingTask?, complete: @escaping @Sendable (Bool) -> Void) {
        self.rawTask = rawTask
        self.complete = complete
    }

    /// Production convenience: wraps a live task, completing it via its own
    /// `setTaskCompleted(success:)` when the session decides it's done.
    static func live(_ task: BGProcessingTask) -> MigrationBGSessionHandle {
        MigrationBGSessionHandle(rawTask: task, complete: { task.setTaskCompleted(success: $0) })
    }
}

extension MigrationBGSessionHandle: Equatable {
    /// `complete` is a closure and can't be compared — identity of the wrapped task (or "both
    /// nil", the spy-handle shape every test uses) is the only meaningful equality here.
    static func == (lhs: MigrationBGSessionHandle, rhs: MigrationBGSessionHandle) -> Bool {
        lhs.rawTask === rhs.rawTask
    }
}

/// MOB-1496 (W5): one candidate account's classification within a single migration BG session,
/// computed by `migrationBackgroundSessionEffect`'s per-account probe (`classifyMigrationAccount`)
/// and consumed by `MigrationSessionPlanner.plan(_:)` to pick the session's single action. Mirrors
/// the ordered classification the spec's "Per-account background decision tree" describes.
private enum MigrationAccountClassification: Equatable {
    /// `complete`/`notStarted`/`readyToPropose` — no broadcast, no sync need for this account.
    case nothingToDo(MigrationState)
    /// `hasInvalidMigrationTransfers` OR state is `.requiresAttention(.transferExpired)` /
    /// `.requiresAttention(.invalidTransfer)`.
    case planBroken
    /// `isSyncRequiredBeforeNextMigrationTransfer` is true.
    case syncNeeded
    /// `rescheduleOverdueMigrationTransfer` returned a proposal — a candidate for this session's
    /// single broadcast, ordered by `isOverdue` then `nextExecutableAfterHeight`. Due-ness itself is
    /// NOT decided here (see `migrationBackgroundSessionEffect`'s "height-due semantics" doc) —
    /// `executeNextPendingMigrationTransfer`'s own nil-return is the authority.
    case broadcastCandidate(nextExecutableAfterHeight: BlockHeight, isOverdue: Bool)
    /// An active run (not `nothingToDo`/`planBroken`/`syncNeeded`) whose reschedule probe came back
    /// nil — nothing pending to order against this session, but still an active run (excluded from
    /// the "every account complete/notStarted" cancel-all trigger).
    case activeNoCandidate
    /// A `try?`-guarded read failed for this account — logged and skipped; conservatively excluded
    /// from the cancel-all trigger too (its true state is unknown).
    case unreadable
}

/// MOB-1496 (W5): classifies one account for `migrationBackgroundSessionEffect`'s per-account probe.
/// Every SDK read is `try?`-guarded — log-and-skip per the existing single-account pattern (MOB-1496
/// W1-W4): a read failure degrades this ONE account to `.unreadable` rather than aborting the whole
/// session.
private func classifyMigrationAccount(
    _ accountUUID: AccountUUID,
    sdkSynchronizer: SDKSynchronizerClient
) async -> MigrationAccountClassification {
    guard let migrationState = try? await sdkSynchronizer.getMigrationState(accountUUID) else {
        LoggerProxy.error("BGTask migration session: state read failed for an account")
        return MigrationAccountClassification.unreadable
    }

    switch migrationState {
    // `.readyToPropose` is never actually emitted by the final migration engine — kept here only
    // for exhaustiveness / the migration SDK simulator, which still models it.
    case MigrationState.complete, MigrationState.notStarted, MigrationState.readyToPropose:
        return MigrationAccountClassification.nothingToDo(migrationState)
    default:
        break
    }

    guard let hasInvalid = try? await sdkSynchronizer.hasInvalidMigrationTransfers(accountUUID) else {
        LoggerProxy.error("BGTask migration session: plan-broken check failed for an account")
        return MigrationAccountClassification.unreadable
    }

    let isPlanBrokenByState: Bool
    switch migrationState {
    case MigrationState.requiresAttention(MigrationAttentionReason.transferExpired),
         MigrationState.requiresAttention(MigrationAttentionReason.invalidTransfer):
        isPlanBrokenByState = true
    default:
        isPlanBrokenByState = false
    }

    if hasInvalid || isPlanBrokenByState {
        return MigrationAccountClassification.planBroken
    }

    guard let isSyncRequired = try? await sdkSynchronizer.isSyncRequiredBeforeNextMigrationTransfer(accountUUID) else {
        LoggerProxy.error("BGTask migration session: sync-required check failed for an account")
        return MigrationAccountClassification.unreadable
    }

    if isSyncRequired {
        return MigrationAccountClassification.syncNeeded
    }

    // Double-optional flatten: `rescheduleOverdueMigrationTransfer` already returns an Optional on
    // success, and `try?` adds a second layer — a thrown read and a genuinely-empty probe both read
    // as "no candidate" here (mirrors `MigrationManagerImpl.migrationSummary`'s identical `residual`
    // flatten). Per the tree's "height-due semantics" doc, a nil probe is NOT itself an error worth
    // logging — it just means nothing is pending to order against this session.
    let proposal = (try? await sdkSynchronizer.rescheduleOverdueMigrationTransfer(accountUUID)) ?? nil
    guard let proposal else {
        return MigrationAccountClassification.activeNoCandidate
    }

    let isOverdue = (try? await sdkSynchronizer.hasOverdueMigrationTransfers(accountUUID)) ?? false
    return MigrationAccountClassification.broadcastCandidate(
        nextExecutableAfterHeight: proposal.nextExecutableAfterHeight,
        isOverdue: isOverdue
    )
}

/// MOB-1496 (W5): pure per-session resolution — table-testable given already-classified accounts, no
/// SDK dependency. Mirrors `WakeupAction.decide`'s "pure decision, effectful caller" split; verified
/// indirectly here via the Store-level `RootMigrationBackgroundTests` (this file has no direct-SDK
/// escape hatch the way `MigrationCadence`/`WakeupAction` do, since account CLASSIFICATION itself
/// needs async SDK reads — only the RESOLUTION over already-classified accounts is pure).
private enum MigrationSessionPlanner {
    struct Plan: Equatable {
        let notifyPlanNeedsUpdate: Bool
        /// R8-T5 (S4): the FIRST plan-broken account found (selected-first order, same "whichever"
        /// tie-break the rest of this planner already uses) — carried so the `.planNeedsUpdate`
        /// notification can be attributed to the account that actually needs attention, instead of
        /// composing for the session's broadcast winner: a DIFFERENT, healthy account may be the one
        /// that broadcasts this very session (see `plan(_:)`'s ordering doc — a plan-broken account
        /// does not block a healthy account's own broadcast/sync). `nil` exactly when
        /// `notifyPlanNeedsUpdate` is `false`.
        let planBrokenAccountUUID: AccountUUID?
        let action: Action

        enum Action: Equatable {
            case syncOnly
            case broadcast(winner: AccountUUID)
            case cancelAll
            case rearm
            /// Plan-broken-only (nothing else fired this session): no rearm, no cancel — mirrors the
            /// single-account precedent (a broken plan needs the user's own Recovery-flow re-arm,
            /// not an automatic retry).
            case none
        }
    }

    /// Session resolution, checked in this exact order (spec "Session resolution"):
    /// 1. Any `planNeedsUpdate` account -> notify once for the whole session; continue evaluating
    ///    the rest (a plan-broken account doesn't block a healthy account's own broadcast/sync).
    /// 2. Any `syncNeeded` account -> sync-only session; ALL broadcasts deferred (ZIP: never both).
    /// 3. Else any `broadcastCandidate` -> pick exactly one (prefer overdue; earliest
    ///    `nextExecutableAfterHeight`; tie -> earliest in `classifications`' own order, i.e. the
    ///    selected account, since callers pass accounts selected-first).
    /// 4. Nothing else fired: plan-broken-only -> `.none` (no rearm, no cancel); else cancelAll when
    ///    EVERY classified account is `.complete`/`.notStarted` (no active run anywhere); else rearm.
    static func plan(_ classifications: [(accountUUID: AccountUUID, classification: MigrationAccountClassification)]) -> Plan {
        let hasSyncNeeded = classifications.contains { if case .syncNeeded = $0.classification { return true } else { return false } }
        // R8-T5 (S4): the FIRST plan-broken account (selected-first order) — non-nil exactly when a
        // plan-broken account exists, so this doubles as the old `hasPlanBroken` check too.
        let planBrokenAccountUUID = classifications.first { if case .planBroken = $0.classification { return true } else { return false } }?.accountUUID

        if hasSyncNeeded {
            return Plan(notifyPlanNeedsUpdate: planBrokenAccountUUID != nil, planBrokenAccountUUID: planBrokenAccountUUID, action: Plan.Action.syncOnly)
        }

        if let winner = pickBroadcastWinner(classifications) {
            return Plan(
                notifyPlanNeedsUpdate: planBrokenAccountUUID != nil,
                planBrokenAccountUUID: planBrokenAccountUUID,
                action: Plan.Action.broadcast(winner: winner)
            )
        }

        if let planBrokenAccountUUID {
            return Plan(notifyPlanNeedsUpdate: true, planBrokenAccountUUID: planBrokenAccountUUID, action: Plan.Action.none)
        }

        let everyAccountIsCompleteOrNotStarted = !classifications.isEmpty && allAccountsAreDone(classifications)

        return Plan(
            notifyPlanNeedsUpdate: false,
            planBrokenAccountUUID: nil,
            action: everyAccountIsCompleteOrNotStarted ? Plan.Action.cancelAll : Plan.Action.rearm
        )
    }

    /// A single account's classification counts as "done" (no active run) for the cancel-all gate
    /// below — `.complete`/`.notStarted` only. `.readyToPropose` (a real balance, no committed plan
    /// yet) and `.unreadable` (an unknown true state) both deliberately do NOT count as done, so
    /// either one blocks a premature cancelAll and keeps the wakeup chain alive instead.
    ///
    /// MOB-1496 (fix-wave, review IMPORTANT-1): also reused by `handleLandedBroadcast`'s own
    /// post-broadcast complete-check, via `allAccountsAreDone` below, so the two "is everyone
    /// really done" sites can't drift apart.
    static func isDoneClassification(_ classification: MigrationAccountClassification) -> Bool {
        guard case let .nothingToDo(state) = classification else { return false }
        return state == MigrationState.complete || state == MigrationState.notStarted
    }

    /// True only when EVERY entry in `classifications` is done (`isDoneClassification`) —
    /// vacuously true for an EMPTY list, matching `Array.allSatisfy`'s own empty-collection
    /// semantics (a broadcast winner with no OTHER classified accounts this session IS "every other
    /// account done"). `plan(_:)` above additionally guards the TOTAL account set against being
    /// empty itself (defensive — never actually empty by the time a session reaches this code);
    /// `handleLandedBroadcast`'s own "every OTHER account" check deliberately does NOT apply that
    /// same guard, so a single-account session's landed broadcast still cancels exactly as it
    /// always has.
    static func allAccountsAreDone(
        _ classifications: [(accountUUID: AccountUUID, classification: MigrationAccountClassification)]
    ) -> Bool {
        classifications.allSatisfy { isDoneClassification($0.classification) }
    }

    /// A broadcast candidate mid-comparison in `pickBroadcastWinner` — a small named type instead
    /// of a 3-member tuple (SwiftLint's `large_tuple` caps tuples at 2 members).
    private struct BroadcastCandidate {
        let accountUUID: AccountUUID
        let height: BlockHeight
        let isOverdue: Bool
    }

    /// Prefers a candidate with the overdue flag; among several, earliest `nextExecutableAfterHeight`;
    /// a tie keeps whichever the loop reached first — callers pass accounts selected-first, so that
    /// is the selected account per the spec's own tie-break rule.
    private static func pickBroadcastWinner(
        _ classifications: [(accountUUID: AccountUUID, classification: MigrationAccountClassification)]
    ) -> AccountUUID? {
        var winner: BroadcastCandidate?

        for (accountUUID, classification) in classifications {
            guard case let .broadcastCandidate(height, isOverdue) = classification else { continue }

            guard let current = winner else {
                winner = BroadcastCandidate(accountUUID: accountUUID, height: height, isOverdue: isOverdue)
                continue
            }

            let isBetter: Bool
            if isOverdue != current.isOverdue {
                isBetter = isOverdue
            } else if height != current.height {
                isBetter = height < current.height
            } else {
                isBetter = false
            }

            if isBetter {
                winner = BroadcastCandidate(accountUUID: accountUUID, height: height, isOverdue: isOverdue)
            }
        }

        return winner?.accountUUID
    }
}

/// MOB-1496 (fix-wave, review MINOR-4): bundles the 4 dependency clients
/// `migrationBackgroundSessionEffect`'s `.run` closure captures, so the per-plan-action handlers
/// extracted out of that closure (`runMigrationSession` and friends, below in `extension Root`)
/// take one parameter instead of four apiece. Plain explicit-value capture (matching this file's
/// existing "capture specific dependency values, never `self`" idiom) — every field is itself
/// `Sendable`, so this struct is too.
private struct MigrationSessionDependencies: Sendable {
    let migrationManager: MigrationManagerClient
    let sdkSynchronizer: SDKSynchronizerClient
    let migrationBGScheduler: MigrationBGSchedulerClient
    let userNotifications: UserNotificationsClient
}

/// In this file is a collection of helpers that control all state and action related operations
/// for the `Root` with a connection to the app/wallet initialization and erasure of the wallet.
extension Root {
    enum Constants {
        static let udIsRestoringWallet = "udIsRestoringWallet"
        static let udIsResyncingWallet = "udIsResyncingWallet"
        static let udLeavesScreenOpen = "udLeaves_screen_open"
        static let noAuthenticationWithinXMinutes = 15
    }
    
    enum InitializationAction {
        case appDelegate(AppDelegateAction)
        case checkBackupPhraseValidation
        case checkRestoreWalletFlag(SyncStatus)
        case checkWalletInitialization
        case checkWalletConfig
        /// R9-T5 (finding 7): the trigger for `migrationManager.clearAbandonedNetworkSnapshot(_:)`
        /// — a pre-commit snapshot abandoned by killing the app mid-flow (which never reaches
        /// `.migrationCoordFlow(.flowFinished)`, the only OTHER trigger — see `RootCoordinator`)
        /// would otherwise survive forever instead of being cleared. Sent from TWO sites, both
        /// needed (final-review IMPORTANT-1): (1) `.initialSetups`'s reconcile effect, once
        /// `migrationManager.reconcile()` completes — covers a WARM re-init
        /// (`willEnterForeground` unprepared/locked, `walletConfigChanged` re-entry) where accounts
        /// are already populated from earlier in this same process; (2) `.loadedWalletAccounts`,
        /// once the SDK's own account list lands in state — the site that actually fires on a
        /// genuine COLD launch, since `.initialSetups` runs long before accounts exist or the SDK
        /// is prepared there (see that send site's doc for the empty-candidate-list/unprepared-SDK
        /// walk). Both sites share the SAME flow-open guard on this action's reducer arm below —
        /// see there for why it's needed.
        case clearAbandonedMigrationSnapshots
        case initializeSDK(WalletInitMode)
        case staleWalletDatabaseHealed
        case presentStaleWalletHealedAlert
        case initialSetups
        case initializationFailed(ZcashError)
        case initializationSuccessfullyDone
        case loadedWalletAccounts([WalletAccount])
        case migrationBackgroundSession(MigrationBGSessionHandle)
        /// R8-T5 (S4): fires after `.migrationNotificationTapped`'s account-switch effect (`.home
        /// (.walletAccountTapped(_:))`) completes — `.concatenate` orders the two dispatches so the
        /// migration flow opens only once the switch is fully applied. See
        /// `migrationNotificationTappedRoutingEffect`'s doc.
        case migrationNotificationRoute
        /// MOB-1496 (R8-T4, #11): the migration BG session tree's own "I'm done" round-trip —
        /// effects can't mutate `state` directly, so both `runMigrationSession`'s normal-completion
        /// tail and `completeSyncOnlySession`'s gate-blocked branch send this instead of calling
        /// `handle.complete(_:)` inline. The reducer guards on `state
        /// .activeMigrationBackgroundSessionHandle` being non-nil before completing AND clears it
        /// first — see that state property's doc for why (double-complete safety against
        /// `.migrationBackgroundTaskExpired`).
        case migrationBackgroundSessionCompleted(Bool)
        /// MOB-1496: the migration BG decision tree's "sync required, not deferred" branch needs to
        /// mutate `state.bgTask` — effects can't do that directly, so the async decision tree
        /// (`migrationBackgroundSessionEffect`'s `.run`) sends this back into the reducer instead of
        /// setting it inline the way the pre-real-SDK synchronous version did.
        case migrationBackgroundSyncOnly(MigrationBGSessionHandle)
        /// MOB-1496 (W3): `.retryStart`'s `.run` effect can't mutate `state` directly — sent back
        /// into the reducer (proactively, before ever calling `start`, or reactively after `start`
        /// throws `ZcashError.migrationSyncBlocked`) to set `state.syncDeferredByMigrationGate`.
        /// R8-T6: also sent for the SAME reason when a Send-now silence-window wait's own hold flag
        /// (`migrationSendWaitActive`) is set — one flag/replay path safely covers both "sync must
        /// stay stopped" reasons, since `.retryStart`'s own re-check at replay time re-validates
        /// BOTH conditions fresh regardless of which one caused the original defer.
        case migrationSyncDeferredByGate
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
                state.appStartState = .didFinishLaunching
                // TODO: [#704], trigger the review request logic when approved by the team,
                // https://github.com/Electric-Coin-Company/zashi-ios/issues/704
                return .run { send in
                        try await mainQueue.sleep(for: .seconds(0.5))
                        await send(.initialization(.initialSetups))
                    }
                    .cancellable(id: state.DidFinishLaunchingId, cancelInFlight: true)

            case .initialization(.appDelegate(.willEnterForeground)):
                if state.featureFlags.appLaunchBiometric {
                    let now = Date()
                    let before = Date.init(timeIntervalSince1970: TimeInterval(state.lastAuthenticationTimestamp))
                    if let xMinutesAgo = Calendar.current.date(byAdding: .minute, value: -Constants.noAuthenticationWithinXMinutes, to: now),
                       before < xMinutesAgo {
                        state.splashAppeared = false
                    }
                }
                state.appStartState = .willEnterForeground
                // MOB-1466: reconcile migration state on every foreground entry (idempotent
                // `migrationManager.reconcile()` + the stale-acknowledge reset) so a banner/
                // re-entry route that changed while backgrounded is picked up promptly. Banner
                // freshness itself stays reactive (SmartBanner's own subscription + walk) — this
                // is deliberately the minimal Root-side hook the spec calls for.
                let reconcileEffect: Effect<Action> = .run { [migrationManager] _ in await migrationManager.reconcile() }
                // MOB-1467: opening the app clears stale migration notifications from Notification
                // Center — the banner/re-entry route now carries the current state. Delivered ONLY:
                // a pending manual-mode "ready to send" reminder must survive foreground entry.
                let clearDeliveredEffect: Effect<Action> = .run { [userNotifications] _ in
                    await userNotifications.clearDeliveredMigrationNotifications()
                }
                if state.isLockedInKeychainUnavailableState || !sdkSynchronizer.latestState().syncStatus.isPrepared {
                    return .merge(reconcileEffect, clearDeliveredEffect, .send(.initialization(.initialSetups)))
                } else {
                    return .merge(reconcileEffect, clearDeliveredEffect, .send(.initialization(.retryStart)))
                }
                
            case .initialization(.appDelegate(.didEnterBackground)):
                sdkSynchronizer.stop()
                state.bgTask?.setTaskCompleted(success: false)
                state.bgTask = nil
                state.appStartState = .didEnterBackground
                state.isLockedInKeychainUnavailableState = false
                return .merge(
                    .cancel(id: state.CancelStateId),
                    .cancel(id: state.CancelTransactionsStateId)
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

            case .initialization(.appDelegate(.migrationBackgroundTask(let task))):
                // Immediately wrapped so the decision tree below (`.migrationBackgroundSession`)
                // never touches a raw `BGProcessingTask` directly — that type can't be
                // instantiated in unit tests, so `RootMigrationBackgroundTests` drives
                // `.migrationBackgroundSession` with spy handles instead (`rawTask: nil`).
                return .send(.initialization(.migrationBackgroundSession(MigrationBGSessionHandle.live(task))))

            case .initialization(.migrationBackgroundSession(let handle)):
                // MOB-1496 (R8-T4, #7): a cold launch races this dispatch against wallet-state
                // hydration — the SAME deep-link stash treatment `.migrationNotificationTapped`
                // above already uses: stash until `checkBackupPhraseValidation`'s "just reached
                // Home" checkpoint replays it, rather than letting `migrationBackgroundSessionEffect`'s
                // own early-return checks run against not-yet-hydrated state (`isIronwoodActivated()`'s
                // tip==0 fail-safe sentinel, an empty `walletAccounts`) and misread a REAL
                // activated/populated wallet as "nothing to do," consuming the BG request without
                // re-arming. Checked here (rather than in `.appDelegate(.migrationBackgroundTask)`
                // just above) so the stash itself stays exercisable with the spy handles this whole
                // suite already drives — a raw `BGProcessingTask` can't be constructed in tests.
                guard state.appInitializationState == .initialized else {
                    state.pendingMigrationBackgroundSession = handle
                    return .none
                }
                return migrationBackgroundSessionEffect(state: &state, handle: handle)

            case .initialization(.migrationBackgroundSyncOnly(let handle)):
                // R8 final cumulative review (Finding 2): `completeSyncOnlySession` sends this
                // hand-off back into the reducer — but `.migrationBackgroundTaskExpired` can win the
                // race and complete the session FIRST (its guarded active-session branch clears
                // `activeMigrationBackgroundSessionHandle` — see that action's doc) while this send
                // is already in flight and survives the tree's own cancellation. Guard on the SAME
                // live-session marker before adopting anything: `nil` means expiration already
                // completed/re-armed this session, so adopting `handle` into `state.bgTask` here
                // would resurrect a task iOS already considers done (risking a second
                // `setTaskCompleted` on it from a later completion path) and kick a sync start
                // inside a dead BG window.
                guard state.activeMigrationBackgroundSessionHandle != nil else { return .none }

                // Sync-only session: never broadcasts. Re-arm up front, then reuse the
                // `power_wifi_sync` handler's own sync-kick verbatim (`state.bgTask` + `.retryStart`)
                // — `synchronizerStateChanged` completes `state.bgTask` on
                // `.upToDate`/`.stopped`/`.error` exactly as it does for that task. `handle.rawTask`
                // may be `nil` in tests (spy handles); that completion is then a no-op, which is
                // acceptable — this branch is asserted on the arm + kick + stash, not on task
                // completion.
                state.bgTask = handle.rawTask
                // MOB-1496 (R8-T4, #11): this hand-off transitions the handle's completion out of
                // `activeMigrationBackgroundSessionHandle`'s tracking and into `bgTask`'s existing
                // one (just set above) — clear it here so a LATER expiration falls through to the
                // untouched sync-bgTask tail below instead of trying to complete via a stale handle.
                state.activeMigrationBackgroundSessionHandle = nil
                return .concatenate(
                    .run { [migrationBGScheduler] _ in await migrationBGScheduler.scheduleNextWindow() },
                    .send(.initialization(.retryStart))
                )

            case .initialization(.migrationBackgroundSessionCompleted(let success)):
                // MOB-1496 (R8-T4, #11): guard-on-nil — whichever of THIS (normal completion) or
                // `.migrationBackgroundTaskExpired` reaches the (single-threaded) reducer first wins;
                // the other then finds the slot already `nil` and no-ops, so the same
                // `BGProcessingTask` can never be completed twice.
                guard let handle = state.activeMigrationBackgroundSessionHandle else { return .none }
                state.activeMigrationBackgroundSessionHandle = nil
                handle.complete(success)
                return .none

            case .initialization(.appDelegate(.migrationBackgroundTaskExpired)):
                // MOB-1496 (R8-T4, #7): a session stashed pre-init never actually started — release
                // it here rather than betting hydration replays it before the OS reclaims the task;
                // re-arm so the wakeup chain survives regardless.
                if let pendingMigrationBackgroundSession = state.pendingMigrationBackgroundSession {
                    state.pendingMigrationBackgroundSession = nil
                    pendingMigrationBackgroundSession.complete(false)
                    return .run { [migrationBGScheduler] _ in await migrationBGScheduler.scheduleNextWindow() }
                }

                // MOB-1496 (R8-T4, #11): an ACTIVE session tree is genuinely mid-flight (possibly
                // mid-broadcast) — cancel the tree, complete via the STORED handle (never `state
                // .bgTask`, which stays `nil` for this plan — see `MigrationBGSessionHandle`'s doc),
                // clear the stash, and re-arm. `handle.complete(false)` here races
                // `.migrationBackgroundSessionCompleted`'s own guard (see its doc); whichever gets
                // to the slot first wins, so the two can never double-complete.
                if let activeMigrationBackgroundSessionHandle = state.activeMigrationBackgroundSessionHandle {
                    state.activeMigrationBackgroundSessionHandle = nil
                    activeMigrationBackgroundSessionHandle.complete(false)
                    return .merge(
                        .cancel(id: state.migrationBackgroundSessionCancelId),
                        .run { [migrationBGScheduler] _ in await migrationBGScheduler.scheduleNextWindow() }
                    )
                }

                // Mirror `didEnterBackground`'s expiration handling for the existing
                // `power_wifi_sync` task: stop the synchronizer and release `state.bgTask` (a
                // sync-only session may have set it), then re-arm — an expired session must never
                // orphan the wakeup chain. Re-submitting with the same identifier REPLACES the
                // pending request, so this is safe even if branch 3's up-front re-arm already ran
                // in this same session.
                sdkSynchronizer.stop()
                state.bgTask?.setTaskCompleted(success: false)
                state.bgTask = nil
                // MOB-1483: pre-activation, branch 1 of the decision tree below never arms in the
                // first place — skip the re-arm here too, for the same reason: there's nothing to
                // keep alive, so let the wakeup chain lapse rather than resurrect a stale one.
                if !migrationManager.isIronwoodActivated() {
                    return .none
                }
                return .run { [migrationBGScheduler] _ in await migrationBGScheduler.scheduleNextWindow() }

            case .initialization(.appDelegate(.migrationNotificationTapped(let accountUUID))):
                // Same gate as `checkBackupPhraseValidation` uses for `isAtDeeplinkWarningScreen`:
                // `.initialized` is set exactly once, at that checkpoint, so it doubles as "Home
                // is up" here. If we're not there yet (cold start still in flight), stash the
                // request — `checkBackupPhraseValidation` fires it once initialization completes.
                // R8-T5 (S4): the stash now carries the tapped notification's account too, so the
                // deferred replay can switch accounts exactly like the immediate path below does.
                guard state.appInitializationState == .initialized else {
                    state.pendingMigrationDeepLink = true
                    state.pendingMigrationDeepLinkAccountUUID = accountUUID
                    return .none
                }
                return migrationNotificationTappedRoutingEffect(state: &state, accountUUID: accountUUID)

            case .initialization(.migrationNotificationRoute):
                // R8-T5 (S4): see `migrationNotificationTappedRoutingEffect`'s doc — reached only
                // after the account-switch effect it dispatched ahead of this has completed.
                return openMigrationCoordFlow(state: &state)

            case .synchronizerStateChanged(let latestState):
                let snapshot = SyncStatusSnapshot.snapshotFor(state: latestState.data.syncStatus)

                // MOB-1496 (W2): reconcile migration state on the EDGE into `.upToDate` — not on
                // every tick while already synced (would storm `reconcile()` on every subsequent
                // tick at the tip). Piggybacks on this existing `stateStream()` subscription
                // (`.registerForSynchronizersUpdate` below) rather than opening a second one.
                // MOB-1496 (W3): `recordSyncCompleted()` re-keys the app's send gate off this SAME
                // edge — once per completed sync, not per tick, exactly like `reconcile()` beside
                // it (see `MigrationManagerClient.recordSyncCompleted`'s doc).
                let didJustReachUpToDate = snapshot.syncStatus == .upToDate && !state.wasSyncUpToDateForMigration
                state.wasSyncUpToDateForMigration = snapshot.syncStatus == .upToDate
                let migrationReconcileEffect: Effect<Action> = didJustReachUpToDate
                    ? .run { [migrationManager] _ in
                        migrationManager.recordSyncCompleted()
                        await migrationManager.reconcile()
                      }
                    : .none

                guard let account = state.selectedWalletAccount else {
                    return migrationReconcileEffect
                }

                // update flexa balance
                if let accountBalance = latestState.data.accountsBalances[account.id] {
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

                // handle BCGTask
                guard state.bgTask != nil else {
                    return .merge(migrationReconcileEffect, .send(.initialization(.checkRestoreWalletFlag(snapshot.syncStatus))))
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
                    return .merge(
                        migrationReconcileEffect,
                        .cancel(id: state.CancelStateId),
                        .cancel(id: state.CancelTransactionsStateId)
                    )
                }

                return .merge(migrationReconcileEffect, .send(.initialization(.checkRestoreWalletFlag(snapshot.syncStatus))))

            // MOB-1496 (W2): gate-flip migration-reconcile trigger — see
            // `.registerForSynchronizersUpdate`'s `migrationSyncGateEffect` for how this is fed.
            // MOB-1496 (W3): also the resume point for `.retryStart`'s deferral — a flip to
            // NOT-blocked while a start was deferred clears the flag and replays `.retryStart` so
            // the normal chain resumes identically to an ungated launch. The flag clears BEFORE
            // the replay, so a still-blocked re-entry (the proactive check in `.retryStart` reads
            // the gate fresh) just re-defers rather than looping.
            //
            // MOB-1496 (W3 review fix B): a foreground broadcast's stop (`SDKSynchronizerClient
            // .stopSyncBeforeMigrationBroadcast()`) must also guarantee a resume once the gate
            // clears, even when `syncDeferredByMigrationGate` was never set — that flag only gets
            // set when a `.retryStart` happens to run (and defer) WHILE the gate is blocked; a user
            // who never triggers one (e.g. parked on the note-split progress screen) would
            // otherwise stall until an unrelated app-lifecycle event. `migrationStoppedSyncForBroadcast`
            // (the shared flag that helper sets) covers that gap: resuming is now checked
            // independent of `isGenuineChange` (moved ahead of the dedupe early-return) so it isn't
            // gated on a genuine transition arriving at all. This also covers the edge where the
            // gate never blocks in the first place (a broadcast fails pre-flight, e.g. a Tor
            // bootstrap error, before it ever reaches the SDK's own gate-setting code) — no
            // `true->false` transition will EVER arrive for that case, but the flag stays set until
            // the NEXT `.migrationSyncGateChanged(false)` reaches here regardless of source (the
            // seed read this same subscription re-sends on every future successful start), which
            // this now resumes on too rather than letting the dedupe swallow it as "no change".
            // `reconcile()` itself stays gated on a genuine change only — unrelated concern (banner/
            // re-entry-route derivation), unchanged from W3.
            //
            // Mechanism choice (see fix report for the full write-up): a store cannot reach this
            // action directly (`SDKSynchronizerClient`'s stores are typed to their own reducer's
            // `Action`, not `Root.Action`), stores have no OTHER precedent for kicking sync
            // themselves (`.retryStart` is `RootInitialization.swift`'s confirmed sole choke point —
            // W3 already audited this), and no pre-existing delegate/coordinator chain from any of
            // the four broadcast-bearing stores already serves "resume sync" (the one nested-action
            // match Root has today, `.sending(.delegate(.viewTransaction))`, is unrelated
            // navigation) — building one from scratch would mean four new deep nested-action
            // matches in Root for a single flag check. Extending this already-existing, already-
            // subscribed handler is the deterministic option that adds no new plumbing.
            case .migrationSyncGateChanged(let isBlocked):
                @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false

                let isGenuineChange = isBlocked != state.lastMigrationSyncGateBlocked
                let shouldResume = !isBlocked && (state.syncDeferredByMigrationGate || migrationStoppedSyncForBroadcast)
                guard isGenuineChange || shouldResume else { return .none }

                state.lastMigrationSyncGateBlocked = isBlocked
                let reconcileEffect: Effect<Action> = isGenuineChange
                    ? .run { [migrationManager] _ in await migrationManager.reconcile() }
                    : .none

                guard shouldResume else {
                    return reconcileEffect
                }

                state.syncDeferredByMigrationGate = false
                $migrationStoppedSyncForBroadcast.withLock { $0 = false }
                return .merge(reconcileEffect, .send(.initialization(.retryStart)))

            case .initialization(.checkRestoreWalletFlag(let syncStatus)):
                if state.isRestoringWallet && syncStatus == .upToDate {
                    state.isRestoringWallet = false
                    userDefaults.remove(Constants.udIsRestoringWallet)
                    userDefaults.remove(Constants.udIsResyncingWallet)
                    state.$walletStatus.withLock { $0 = .none }
                }
                return .none

            case .initialization(.synchronizerStartFailed):
                return .none
                
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
                return .run { [state] send in
                    // R8-T6: a Send-now silence-window wait (`MigrationSendingStore`) holds sync
                    // stopped WITHOUT ever touching the SDK's OWN migration-blocked flag below — no
                    // broadcast has been attempted yet, so there's nothing for `isMigrationSyncBlocked()`
                    // to report, and this check would otherwise sail straight through and restart
                    // sync mid-wait. Checked first, ahead of any SDK round-trip, so a live wait can
                    // never lose a race to a slow gate read. Deferred the SAME silent way as the SDK
                    // gate check below — reusing `.migrationSyncDeferredByGate`/
                    // `syncDeferredByMigrationGate` rather than a parallel flag/action: the replay
                    // this needs is EXACTLY `.migrationSyncGateChanged`'s existing resume path
                    // (below), fired once `MigrationSendingStore`'s cancel/broadcast-start path
                    // clears the hold and calls `migrationManager.refreshMigrationSyncGate()`. A
                    // stale replay (the hold still set somehow) just re-defers here — no new loop
                    // risk, mirroring `stillBlockedReEntryReDefersWithoutLooping`'s existing proof
                    // for the SDK gate below.
                    @Shared(.inMemory(.migrationSendWaitActive)) var migrationSendWaitActive: Bool = false
                    if migrationSendWaitActive {
                        await send(.initialization(.migrationSyncDeferredByGate))
                        return
                    }
                    // MOB-1496 (W3): proactive half of the SDK's post-broadcast privacy gate —
                    // checked before ever calling `start`, so a still-blocked window never even
                    // attempts it: no error, no alert, nothing downstream of a successful start
                    // runs. `.migrationSyncGateChanged(false)` (below) replays `.retryStart` once
                    // the gate clears, so the normal chain (start -> registerForSynchronizersUpdate
                    // -> refreshAutomaticServer) resumes identically to an ungated launch.
                    if await sdkSynchronizer.isMigrationSyncBlocked() {
                        await send(.initialization(.migrationSyncDeferredByGate))
                        return
                    }
                    do {
                        try await sdkSynchronizer.start(true)
                        if state.bgTask != nil {
                            LoggerProxy.event("BGTask synchronizer.start() PASSED")
                        }
                        await send(.initialization(.registerForSynchronizersUpdate))
                        await send(.refreshAutomaticServer)
                    } catch ZcashError.migrationSyncBlocked {
                        // MOB-1496 (W3): reactive half — `start` itself raced the gate (blocked in
                        // the window between the proactive check above and the SDK's own attempt).
                        // Same silent deferral; every other error keeps its existing handling below.
                        await send(.initialization(.migrationSyncDeferredByGate))
                    } catch {
                        if state.bgTask != nil {
                            LoggerProxy.event("BGTask synchronizer.start() failed \(error.toZcashError())")
                        }
                        await send(.initialization(.synchronizerStartFailed(error.toZcashError())))
                    }
                }

            case .initialization(.migrationSyncDeferredByGate):
                state.syncDeferredByMigrationGate = true
                return .none

            case .initialization(.registerForSynchronizersUpdate):
                let stateStreamEffect = Effect.publisher {
                    sdkSynchronizer.stateStream()
                        .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                        .map { $0.redacted }
                        .map(Root.Action.synchronizerStateChanged)
                }
                .cancellable(id: state.CancelStateId, cancelInFlight: true)

                // MOB-1496 (W2): gate-flip migration-reconcile trigger. An initial
                // `isMigrationSyncBlocked()` read (its stream seeds a conservative `false`
                // synchronously, corrected asynchronously — see `migrationSyncBlockedStream`'s
                // doc) is `.concatenate`d ahead of the live stream itself (its own first/seed
                // emission dropped, since the initial read already has the real value), under one
                // cancel id so both start/stop together with this subscription's own lifetime.
                //
                // MOB-1496 (R8-T4, #3): merged alongside the SDK's own stream is the manager-owned
                // app-side feed (`migrationManager.migrationSyncGateFeed()`) a broadcast-failure
                // call site nudges (`refreshMigrationSyncGate()`) when it stopped sync for a
                // broadcast that never reached a successful outcome — the SDK's stream above only
                // transitions on a SUCCESSFUL broadcast and dedupes via its own `removeDuplicates()`
                // internally, so that path alone would never re-emit for a pre-broadcast throw or a
                // `.networkError`/`.invalidNote`/`.expired` result. Both feeds funnel into the SAME
                // `.migrationSyncGateChanged` mapping, under the SAME cancel id, so all three
                // (state stream, SDK gate stream, app-side gate feed) start/stop together.
                let migrationSyncGateEffect = Effect.merge(
                    Effect.concatenate(
                        .run { [sdkSynchronizer] send in
                            await send(.migrationSyncGateChanged(await sdkSynchronizer.isMigrationSyncBlocked()))
                        },
                        Effect.publisher {
                            sdkSynchronizer.migrationSyncBlockedStream()
                                .dropFirst()
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
                if !diskSpaceChecker.hasEnoughFreeSpaceForSync() {
                    state.destinationState.preNotEnoughFreeSpaceDestination = state.destinationState.internalDestination
                    return .send(.destination(.updateDestination(.notEnoughFreeSpace)))
                } else if let preNotEnoughFreeSpaceDestination = state.destinationState.preNotEnoughFreeSpaceDestination {
                    state.destinationState.internalDestination = preNotEnoughFreeSpaceDestination
                    state.destinationState.preNotEnoughFreeSpaceDestination = nil
                }
                // TODO: [#524] finish all the wallet events according to definition, https://github.com/Electric-Coin-Company/zashi-ios/issues/524
                LoggerProxy.event(".appDelegate(.didFinishLaunching)")
                /// We need to fetch data from keychain, in order to be 100% sure the keychain can be read we delay the check a bit
                return .merge(
                    // MOB-1466: reconcile migration state once per launch — off the hot path
                    // (`migrationManager.reconcile()` is idempotent), so it never blocks or
                    // reorders the existing wallet-initialization sequence below.
                    // R9-T5 (finding 7): `.clearAbandonedMigrationSnapshots` is chained AFTER
                    // reconcile completes, in this SAME effect, rather than `.merge`d alongside it —
                    // reconcile's own stale-`.notStarted` clear (`clearIfCommitted`) is deliberately
                    // provisional-safe, so ordering doesn't matter for correctness against IT, but
                    // running the abandoned-snapshot fan-out as a distinct step keeps this effect's
                    // shape self-documenting as "reconcile, then a second, unrelated cleanup pass."
                    // Final-review IMPORTANT-1: on a genuine COLD launch this particular send is a
                    // near-total no-op — `state.selectedWalletAccount`/`state.walletAccounts` (both
                    // `@Shared(.inMemory)`) are still nil/empty this early, populated only later by
                    // `.loadedWalletAccounts` (dispatched from inside `.initializeSDK`, after
                    // `sdkSynchronizer.walletAccounts()` succeeds) — so the fan-out below iterates
                    // an empty list, and even a non-empty list would find the manager's own
                    // `migrationState` read nil pre-prepare. `.loadedWalletAccounts`'s OWN send of
                    // this same action (see its case below) is what actually clears an abandoned
                    // snapshot on a cold launch; THIS site earns its keep on the WARM re-init paths
                    // (`willEnterForeground` unprepared/locked, `walletConfigChanged`) where accounts
                    // are already populated from earlier in this same process.
                    .run { [migrationManager] send in
                        await migrationManager.reconcile()
                        await send(.initialization(.clearAbandonedMigrationSnapshots))
                    },
                    .send(.initialization(.checkWalletInitialization))
                )

            case .initialization(.clearAbandonedMigrationSnapshots):
                // R9-T5 (finding 7): GUARDED on the migration flow NOT being open — a cold launch
                // via a migration-notification tap can push `.migrationCoordFlow` open DURING
                // initialization (see `.migrationNotificationTapped`'s stash-and-replay above,
                // and `.migrationNotificationRoute`'s own dispatch chain), racing this launch-side
                // clear against a freshly-formed provisional snapshot; without this guard, the
                // clear could win that race and wipe the snapshot out from under the user after the
                // Tor sheet has already displayed its endpoint (an R13 violation on confirm). `state
                // .path == .migrationCoordFlow` is the same presence check `RootCoordinator`'s own
                // teardown sites key off (set at every "open the flow" site, cleared by
                // `.flowFinished`/the Sending-delegate flow-close case) — checked here purely to
                // close the LAUNCH-side race. The residual window — the flow opens WHILE a clear is
                // already in flight — is the same accepted window `.migrationCoordFlow
                // (.flowFinished)`'s own fire-and-forget clear already lives with (see that case's
                // doc): human-speed flow entry makes it practically unreachable in practice. This
                // ONE handler is shared by BOTH send sites (`.initialSetups` and
                // `.loadedWalletAccounts` — see this action's case doc) — the guard is evaluated
                // identically regardless of which one fired it; the notification-tap race is if
                // anything MORE relevant at the `.loadedWalletAccounts` send, since it fires later
                // in the cold-launch sequence, giving a stashed notification tap more time to have
                // already replayed and opened the flow by then.
                guard state.path != Root.State.Path.migrationCoordFlow else { return .none }

                // Same candidate-account list `reconcile()` itself uses — selected account first,
                // then the rest of `walletAccounts`, deduped.
                let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
                    selectedAccountUUID: state.selectedWalletAccount?.id,
                    walletAccounts: state.walletAccounts
                )
                return .run { [migrationManager, accountUUIDs] _ in
                    for accountUUID in accountUUIDs {
                        await migrationManager.clearAbandonedNetworkSnapshot(accountUUID)
                    }
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
                do {
                    let storedWallet: StoredWallet
                    do {
                        storedWallet = try walletStorage.exportWallet()
                    } catch {
                        return .send(.destination(.updateDestination(.osStatusError)))
                    }
                    let birthday = storedWallet.birthday?.value() ?? zcashSDKEnvironment.latestCheckpoint()
                    try mnemonic.isValid(storedWallet.seedPhrase.value())
                    let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                    
                    return .run { send in
                        do {
                            // [#1755] The SDK derives the init flow from the birthday: a brand-new wallet
                            // passes nil (the SDK picks a reorg-safe recent height), restore/existing pass
                            // the stored birthday. `walletMode` is no longer handed to the SDK.
                            let result = try await sdkSynchronizer.prepareWith(
                                seedBytes,
                                walletMode == .newWallet ? nil : birthday,
                                String(localizable: .accountsZashi),
                                String(localizable: .accountsZashi).lowercased()
                            )

                            let healed: Bool
                            switch result {
                            case .seedRequired:
                                throw ZcashError.synchronizerNotPrepared
                            case .seedNotRelevant, .success:
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
                            }
                            if healed {
                                await send(.initialization(.staleWalletDatabaseHealed))
                            }

                            await send(.fetchTransactionsForTheSelectedAccount)
                            /// The TCA spins an async Task in `fetchTransactionsForTheSelectedAccount` and it's needed to run
                            /// before next code here therefore Task is asleep for 0.01s. The purpose is also to not block the main thread
                            /// so await of mainQueue is not used.
                            try? await Task.sleep(nanoseconds: 10_000_000)

                            let walletAccounts = try await sdkSynchronizer.walletAccounts()
                            await send(.initialization(.loadedWalletAccounts(walletAccounts)))
                            await send(.resolveMetadataEncryptionKeys)
                            await send(.loadUserMetadata)

                            // MOB-1496 (R8-T4, #2): mirrors `.retryStart`'s proactive check AND
                            // reactive catch exactly — but, unlike `.retryStart`, defers ONLY this
                            // `start` call: the rest of this cold-start chain (account selection,
                            // exchange-rate refresh, address-book key import) and, critically,
                            // `.initializationSuccessfullyDone` below still run either way, so
                            // `.registerForSynchronizersUpdate` brings up the state-stream AND
                            // gate-resume subscriptions even inside the post-broadcast privacy
                            // window — otherwise nothing would ever observe the gate clearing, and
                            // `.retryStart` would never get replayed to perform the deferred start.
                            // The generic catch below keeps handling every other error exactly as
                            // before.
                            if await sdkSynchronizer.isMigrationSyncBlocked() {
                                await send(.initialization(.migrationSyncDeferredByGate))
                            } else {
                                do {
                                    try await sdkSynchronizer.start(false)
                                } catch ZcashError.migrationSyncBlocked {
                                    // Reactive half — `start` itself raced the gate (blocked in the
                                    // window between the proactive check above and the SDK's own
                                    // attempt). Same silent deferral.
                                    await send(.initialization(.migrationSyncDeferredByGate))
                                }
                            }

                            var selectedAccount: WalletAccount?
                            
                            for account in walletAccounts {
                                if account.vendor == .zcash {
                                    selectedAccount = account
                                }
                            }

                            exchangeRate.refreshExchangeRateUSD()

                            if let account = selectedAccount {
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
                            // existing restore path.
                            await send(.initialization(.checkWalletInitialization))
                        } catch {
                            await send(.initialization(.initializationFailed(error.toZcashError())))
                        }
                    }
                } catch {
                    return .send(.initialization(.initializationFailed(error.toZcashError())))
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

            case .initialization(.initializationSuccessfullyDone):
                return .merge(
                    .send(.initialization(.registerForSynchronizersUpdate)),
                    .publisher {
                        autolockHandler.batteryStatePublisher()
                            .map { _ in Root.Action.batteryStateChanged }
                    }
                    .cancellable(id: state.CancelBatteryStateId, cancelInFlight: true),
                    .send(.batteryStateChanged),
                    .send(.observeTransactions),
                    .send(.observeShieldingProcessor),
                    .send(.observeTorInit),
                    .send(.refreshAutomaticServer)
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
                    // R9-T5 fix (final-review IMPORTANT-1): the trigger that actually clears an
                    // abandoned snapshot on a genuine COLD launch — `.initialSetups`'s own send
                    // (chained after `reconcile()`) fires long before this point, when
                    // `walletAccounts`/`selectedWalletAccount` are still empty/nil and the SDK
                    // isn't prepared yet, so it fans over an empty candidate list and no-ops (see
                    // that send site's doc). HERE both are populated just above AND the SDK is
                    // provably prepared (this handler only runs after `sdkSynchronizer
                    // .walletAccounts()` succeeded). Safe to double-fire alongside `.initialSetups`'s
                    // send on the WARM re-init paths where accounts were already populated from
                    // earlier in this same process: the shared handler's flow-open guard,
                    // `clearAbandonedNetworkSnapshot`'s own idempotent no-op (nothing left to clear
                    // the second time), and the manager's serial executor make a repeat call
                    // harmless.
                    .send(.initialization(.clearAbandonedMigrationSnapshots))
                )

            case .resolveMetadataEncryptionKeys:
                do {
                    let storedWallet: StoredWallet
                    do {
                        storedWallet = try walletStorage.exportWallet()
                    } catch {
                        return .send(.destination(.updateDestination(.osStatusError)))
                    }
                    try mnemonic.isValid(storedWallet.seedPhrase.value())
                    let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                    
                    return .run { [walletAccounts = state.walletAccounts] send in
                        do {
                            
                            for account in walletAccounts {
                                let userMetadataEncryptionKeys = try? walletStorage.exportUserMetadataEncryptionKeys(account.account)
                                if userMetadataEncryptionKeys == nil {
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
                                        // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                                    }
                                }
                            }
                        }
                    }
                } catch { }
                return .none
                
            case .initialization(.checkBackupPhraseValidation):
                do {
                    let _ = try walletStorage.exportWallet()
                } catch {
                    return .send(.destination(.updateDestination(.osStatusError)))
                }

                state.appInitializationState = .initialized
                let isAtDeeplinkWarningScreen = state.destinationState.destination == .deeplinkWarning

                // MOB-1467: this is the checkpoint that already knows "we just reached Home from
                // cold start" — mirrors `isAtDeeplinkWarningScreen` immediately above: snapshot +
                // clear the pending flag now, fire its routing in the same delayed effect that
                // sends Home, right alongside it.
                let hasPendingMigrationDeepLink = state.pendingMigrationDeepLink
                state.pendingMigrationDeepLink = false
                // R8-T5 (S4): the stashed tap's account rides along on replay too — see
                // `pendingMigrationDeepLinkAccountUUID`'s doc.
                let pendingMigrationDeepLinkAccountUUID = state.pendingMigrationDeepLinkAccountUUID
                state.pendingMigrationDeepLinkAccountUUID = nil

                // MOB-1496 (R8-T4, #7): the SAME checkpoint replays a `.migrationBackgroundSession`
                // that arrived before this — see `pendingMigrationBackgroundSession`'s doc.
                let pendingMigrationBackgroundSession = state.pendingMigrationBackgroundSession
                state.pendingMigrationBackgroundSession = nil

                return .run { send in
                    // Delay the splash overlay dismissal
                    try await mainQueue.sleep(for: .seconds(0.5))
                    if !isAtDeeplinkWarningScreen {
                        await send(.destination(.updateDestination(Root.DestinationState.Destination.home)))
                    }
                    if hasPendingMigrationDeepLink {
                        await send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: pendingMigrationDeepLinkAccountUUID))))
                    }
                    if let pendingMigrationBackgroundSession {
                        await send(.initialization(.migrationBackgroundSession(pendingMigrationBackgroundSession)))
                    }
                }
                .cancellable(id: state.CancelId, cancelInFlight: true)
                
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
                return .publisher {
                    wipePublisher
                        .replaceEmpty(with: Void())
                        .map { _ in return Root.Action.resetZashiSDKSucceeded }
                        .replaceError(with: Root.Action.resetZashiSDKFailed)
                        .receive(on: mainQueue)
                }
                .cancellable(id: state.SynchronizerCancelId, cancelInFlight: true)

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
                        try? votingMetadata.resetAccount(account.account)
                    }
                }
                state.walletAccounts.forEach { account in
                    try? walletStorage.clearEncryptionKeys(account.account)
                }
                state.autoUpdateSwapCandidates.removeAll()
                try? userMetadataProvider.reset()
                votingMetadata.reset()
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

                return .send(.resetZashiKeychainRequest)
                
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

                // TODO: [#1627] validate whether this code makes sense
                // https://github.com/zodl-inc/zodl-ios/issues/1627
//                if state.appInitializationState == .keysMissing && state.onboardingState.isImportingWallet {
//                    state.appInitializationState = .uninitialized
//                    return .cancel(id: SynchronizerCancelId)
//                } else if state.appInitializationState == .keysMissing && state.onboardingState.destination == .createNewWallet {
//                    state.appInitializationState = .uninitialized
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.onboarding(.createNewWalletRequested))
//                    )
//                } else {
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.initialization(.checkWalletInitialization))
//                    )
//                }

                // TODO: [#1627] this might need to be recreated
                // https://github.com/zodl-inc/zodl-ios/issues/1627
//                if state.appInitializationState == .keysMissing && state.onboardingState.destination == .importExistingWallet {
//                    state.appInitializationState = .uninitialized
//                    return .cancel(id: SynchronizerCancelId)
//                } else if state.appInitializationState == .keysMissing && state.onboardingState.destination == .createNewWallet {
//                    state.appInitializationState = .uninitialized
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.onboarding(.createNewWalletRequested))
//                    )
//                } else {
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.initialization(.checkWalletInitialization))
//                    )
//                }
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

    // MARK: - MOB-1467: Migration BG session decision tree

    /// The migration BG session's decision tree (spec "Root: BG session decision tree"), checked
    /// in this exact order:
    /// 0. No candidate accounts (MOB-1496: e.g. a background-only cold launch that raced wallet
    ///    initialization) — nothing to evaluate against; complete WITHOUT notifying, but (R8-T4
    ///    #7) DOES re-arm, same as branch 1 below — see that branch's doc for why this changed.
    /// 1. Ironwood not yet activated (MOB-1483) — there is no migration work to do
    ///    pre-activation. Complete the session immediately: no notification, no executor call.
    ///    R8-T4 (#7): DOES re-arm now — `.migrationBackgroundSession`'s own guard (see its doc)
    ///    means this branch only ever runs POST-hydration, so `isIronwoodActivated()` here reflects
    ///    the wallet's REAL activation state, not a cold-launch artifact (a not-yet-`prepare`d
    ///    `latestState()` reads tip 0, which the fail-safe sentinel misreads as "not activated").
    ///    Before that guard existed, a cold launch racing this same check could consume the BG
    ///    request without ever re-arming, permanently killing the wakeup chain — re-arming
    ///    unconditionally here removes that dependency on an untrusted read entirely; a genuinely
    ///    not-yet-activated network just gets an inexpensive, harmless re-check next window.
    /// 2. MOB-1496 (W5): every OTHER candidate account (the wallet's accounts, selected first, then
    ///    stored order — `MigrationDerivations.candidateAccountUUIDs`) is independently classified
    ///    (`classifyMigrationAccount`) into `.nothingToDo`/`.planBroken`/`.syncNeeded`/
    ///    `.broadcastCandidate`/`.activeNoCandidate`/`.unreadable`, then `MigrationSessionPlanner
    ///    .plan(_:)` resolves the WHOLE session to exactly one action:
    ///    - Any plan-broken account -> ONE `.planNeedsUpdate` notification for the whole session
    ///      (not per account); continue evaluating the rest (does not itself block a healthy
    ///      account's own sync/broadcast).
    ///    - Else any sync-needed account -> a sync-only session (skip if the SDK's own
    ///      `isMigrationSyncBlocked()` wallet-scope privacy gate; else the existing sync-kick path,
    ///      reusing the `power_wifi_sync` machinery verbatim). ALL broadcasts deferred this session
    ///      — ZIP-0318: a background session either syncs or broadcasts, never both. Sync serves
    ///      every account at once.
    ///    - Else any broadcast candidate -> exactly ONE broadcast this session (ZIP-0318: no more
    ///      than one overdue transfer sent at wallet open) — `executeNextPendingMigrationTransfer`
    ///      + notify/re-arm per outcome, now parameterized by the WINNING account. A thrown
    ///      `ZcashError.migrationRecordFailedAfterBroadcast` (MOB-1496 W3) is routed through the
    ///      SAME landed-broadcast handling as a `.success` result — the broadcast DID land, only
    ///      the engine's own recording of it failed, so the session must not re-send or treat it as
    ///      a `networkError`. Height-due semantics: the classification's `nextExecutableAfterHeight`
    ///      is for ORDERING/re-arm math only — `executeNextPendingMigrationTransfer`'s own
    ///      nil-return (nothing actually due yet) is the sole due-ness authority. A landed broadcast
    ///      that completes the WINNER only `cancelAll`s/announces `.migrationComplete` when EVERY
    ///      OTHER classified account is ALSO done (`MigrationSessionPlanner.allAccountsAreDone`, the
    ///      SAME predicate the "nothing anywhere" cancelAll gate below uses, so the two can't drift)
    ///      — otherwise it's an ordinary `.transferComplete` + re-arm, so another account's still-
    ///      active run is never orphaned (fix-wave finding 1).
    ///    - Else (nothing anywhere): a plan-broken-only session does NOT re-arm (the user's own
    ///      Recovery-flow re-arms once the plan is fixed); otherwise `cancelAll` when EVERY
    ///      classified account is `.complete`/`.notStarted` (no active run left anywhere —
    ///      preserves the single-account complete->cancelAll precedent), else re-arm.
    /// Every branch except the sync-only session completes `handle` itself (that session's
    /// completion is the existing `synchronizerStateChanged` machinery, exactly like the
    /// `power_wifi_sync` task it mirrors) — R8-T4 (#11): via the guarded
    /// `.migrationBackgroundSessionCompleted` round-trip for the branches below that reach it, so a
    /// concurrent `.migrationBackgroundTaskExpired` can never double-complete the same task (see
    /// that action's doc). Branches 0/1 above complete `handle` directly instead — they're
    /// synchronous/instantaneous (no SDK read, no broadcast), so they never set
    /// `state.activeMigrationBackgroundSessionHandle` in the first place (see below) and have
    /// nothing for expiration to race against.
    ///
    /// MOB-1496: every migration SDK read here is `async throws` (the real per-account surface) —
    /// the whole tree now runs inside one `.run`, and the "sync required, not deferred" branch
    /// sends `.migrationBackgroundSyncOnly(handle)` back into the reducer to mutate `state.bgTask`
    /// (effects can't mutate `state` directly). Every SDK read is wrapped so a thrown error
    /// degrades to "treat as false/skip" and completes the session rather than crashing a
    /// background launch.
    ///
    /// R8-T4 (#11): the tree below (branch 2's fan-out/resolution, the only branch that can
    /// genuinely run long — e.g. mid-broadcast) is `.cancellable(id:
    /// state.migrationBackgroundSessionCancelId)`, and `handle` is stored in
    /// `state.activeMigrationBackgroundSessionHandle` for that effect's whole lifetime — both new
    /// specifically so `.migrationBackgroundTaskExpired` can cancel it and complete it directly
    /// (`state.bgTask` stays `nil` for this plan; only the sync-only hand-off populates it).
    private func migrationBackgroundSessionEffect(
        state: inout Root.State,
        handle: MigrationBGSessionHandle
    ) -> Effect<Root.Action> {
        if !migrationManager.isIronwoodActivated() {
            return .run { [migrationBGScheduler] _ in
                await migrationBGScheduler.scheduleNextWindow()
                handle.complete(true)
            }
        }

        let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: state.selectedWalletAccount?.id,
            walletAccounts: state.walletAccounts
        )
        guard !accountUUIDs.isEmpty else {
            LoggerProxy.event("BGTask migration session: no accounts yet, completing.")
            return .run { [migrationBGScheduler] _ in
                await migrationBGScheduler.scheduleNextWindow()
                handle.complete(true)
            }
        }

        state.activeMigrationBackgroundSessionHandle = handle

        return .run { [migrationManager, sdkSynchronizer, migrationBGScheduler, userNotifications, accountUUIDs] send in
            await Self.runMigrationSession(
                accountUUIDs: accountUUIDs,
                handle: handle,
                send: send,
                dependencies: MigrationSessionDependencies(
                    migrationManager: migrationManager,
                    sdkSynchronizer: sdkSynchronizer,
                    migrationBGScheduler: migrationBGScheduler,
                    userNotifications: userNotifications
                )
            )
        }
        .cancellable(id: state.migrationBackgroundSessionCancelId, cancelInFlight: true)
    }

    /// MOB-1496 (fix-wave, review MINOR-4): classifies every account, resolves the session's single
    /// action via `MigrationSessionPlanner`, and carries it out. Extracted out of
    /// `migrationBackgroundSessionEffect`'s `.run` closure — split into this and the three handlers
    /// below (one per plan action) purely to keep each function's cyclomatic complexity low WITHOUT
    /// a `swiftlint:disable` (not on `SWIFTLINT.md`'s approved-exceptions list); behavior is
    /// byte-for-byte the same as the single giant closure this replaced.
    private static func runMigrationSession(
        accountUUIDs: [AccountUUID],
        handle: MigrationBGSessionHandle,
        send: Send<Root.Action>,
        dependencies: MigrationSessionDependencies
    ) async {
        var classifications: [(accountUUID: AccountUUID, classification: MigrationAccountClassification)] = []
        for accountUUID in accountUUIDs {
            let classification = await classifyMigrationAccount(accountUUID, sdkSynchronizer: dependencies.sdkSynchronizer)
            classifications.append((accountUUID, classification))
        }

        let plan = MigrationSessionPlanner.plan(classifications)

        if plan.notifyPlanNeedsUpdate {
            // R8-T5 (S4): attributed to the plan-broken account, NOT the session's broadcast winner
            // — a different, healthy account may be the one broadcasting this very session (see
            // `MigrationSessionPlanner.Plan.planBrokenAccountUUID`'s doc).
            let planBrokenAccountUUIDString = plan.planBrokenAccountUUID.map { Data($0.id).hexEncodedString() }
            await dependencies.userNotifications.scheduleMigrationNotification(
                MigrationNotification.planNeedsUpdate,
                nil,
                planBrokenAccountUUIDString
            )
        }

        switch plan.action {
        case .syncOnly:
            await completeSyncOnlySession(handle: handle, send: send, dependencies: dependencies)
            return

        case .broadcast(let winnerAccountUUID):
            await executeBroadcastAction(winnerAccountUUID, classifications: classifications, dependencies: dependencies)

        case .cancelAll:
            await dependencies.migrationBGScheduler.cancelAll()

        case .rearm:
            await dependencies.migrationBGScheduler.scheduleNextWindow()

        case .none:
            break
        }

        // R8-T4 (#11): round-trips into the reducer instead of calling `handle.complete(true)`
        // directly — the reducer clears `state.activeMigrationBackgroundSessionHandle` FIRST, so a
        // concurrent `.migrationBackgroundTaskExpired` (which guards on that same slot) can never
        // complete this same `BGProcessingTask` a second time. See
        // `InitializationAction.migrationBackgroundSessionCompleted`'s doc.
        await send(.initialization(.migrationBackgroundSessionCompleted(true)))
    }

    /// The `.syncOnly` plan action: skip the sync session outright while the SDK's wallet-scope
    /// privacy gate reports blocked (MOB-1496 W3 — same outward behavior the retired app-side
    /// `isSyncDeferredAfterBroadcast` flag produced), else kick the same sync path
    /// `power_wifi_sync` uses by handing `handle` back into the reducer as
    /// `.migrationBackgroundSyncOnly` (which stashes `state.bgTask` — effects can't mutate `state`
    /// directly). Either way the session ends here — the caller does NOT complete `handle` again
    /// afterward.
    private static func completeSyncOnlySession(
        handle: MigrationBGSessionHandle,
        send: Send<Root.Action>,
        dependencies: MigrationSessionDependencies
    ) async {
        if await dependencies.sdkSynchronizer.isMigrationSyncBlocked() {
            await dependencies.migrationBGScheduler.scheduleNextWindow()
            // R8-T4 (#11): see `runMigrationSession`'s twin comment above.
            await send(.initialization(.migrationBackgroundSessionCompleted(true)))
            return
        }

        await send(.initialization(.migrationBackgroundSyncOnly(handle)))
    }

    /// The `.broadcast(winner:)` plan action: read the winning account's atomic network-snapshot
    /// options AT EXECUTE TIME (MOB-1496 W4 — never a stale/local value; a missing snapshot this
    /// deep into a BG session self-heals by creating one on the spot, and `createNetworkSnapshot`
    /// logs its own fallback path when the benchmark comes back empty) and attempt the single
    /// broadcast this session is allowed. `executeNextPendingMigrationTransfer`'s own nil-return
    /// remains the sole due-ness authority (the classification height was for ordering/re-arm math
    /// only) — nil, or any other throw, re-arms without a possibly-wrong notification and does NOT
    /// try another candidate (one broadcast per session, full stop).
    /// R7-T3 (MOB-1497): both failure paths below now classify + call `routeBroadcastFailure` before
    /// their existing notification/re-arm handling — see that member's own doc for the R14-R17
    /// decision table. The BACKGROUND lane maps EVERY route to the SAME re-arm-only behavior it
    /// already had: no route changes the notification content or adds a fallback, since consent
    /// (R14's choice, R17's sync-server offer) is strictly foreground-only, and a Tor-class failure
    /// (R14/R15) never rotates by construction (`routeBroadcastFailure` itself enforces this — see
    /// its doc). The ONE state change this lane may observe is `.retryRotated`'s embedded rotation
    /// (performed INSIDE `routeBroadcastFailure`, not here) — rotate-then-re-arm, so the NEXT
    /// session's `migrationNetworkOptions` read picks up the newly-rotated endpoint. The one-
    /// broadcast-per-session invariant is untouched: this call site never retries within the same
    /// session regardless of route.
    ///
    /// R9-T7 (MOB-1497 review remediation, finding 9): this was the ONE broadcast lane that never
    /// called `sdkSynchronizer.stopSyncBeforeMigrationBroadcast()` first — it relied on the SDK's own
    /// during-sync throw (`ZcashError.migrationBroadcastDuringSync`) instead, which is only
    /// advisory/point-in-time (see that method's doc) and never itself resumes sync afterward. An
    /// overlap with an independently-scheduled sync (this app registers three separate
    /// `BGTaskScheduler` tasks, and a foreground sync also qualifies) used to fall through the
    /// generic `catch` below, where the OLD default-arm classification would misreport it as
    /// `.endpointUnreachable` and pollute the persisted R16 rotation episode with a healthy endpoint.
    /// Fixed in two halves: (1) below, mirroring `MigrationSendingStore.executeNextTransfer`'s
    /// `didStopSyncForBroadcast` bookkeeping exactly — stop sync immediately before the broadcast
    /// call, and nudge `refreshMigrationSyncGate()` afterward on every outcome that did NOT land
    /// (the SDK's own gate transition covers a landed broadcast's resume, exactly like Sending);
    /// (2) `MigrationBroadcastFailureClass.classify(error:)` now carves `migrationBroadcastDuringSync`
    /// out to `nil` regardless of lane, so even a race that slips between this stop and the SDK's own
    /// attempt (the guard is still only point-in-time) can never rotate/exhaust — see that method's
    /// doc. Outcome table (stopped/nudged — identical shape to Sending's, since this lane has no
    /// earlier guard that could skip the stop):
    ///   - `.success` (landed): stopped, NOT nudged.
    ///   - `.networkError`/`.invalidNote`/`.expired`: stopped, nudged.
    ///   - `nil` (nothing due): stopped, nudged.
    ///   - catch `migrationRecordFailedAfterBroadcast` (landed): stopped, NOT nudged.
    ///   - catch anything else (incl. Tor-unavailable, and — post carve-out — the nil-classified
    ///     during-sync race): stopped, nudged.
    ///
    /// T5 (MOB-1497): additionally, because this executor is BACKGROUND-only, a Tor-class route
    /// (R14/R15) here arms the per-account "pending background Tor prompt" flag
    /// (`migrationManager.setPendingBackgroundTorPrompt`) so T6 can surface a "Couldn't Connect to Tor"
    /// sheet over Home on the next foreground — see the `catch` clause's own comment for why arming
    /// lives here and not in the shared `routeBroadcastFailure`.
    private static func executeBroadcastAction(
        _ winnerAccountUUID: AccountUUID,
        classifications: [(accountUUID: AccountUUID, classification: MigrationAccountClassification)],
        dependencies: MigrationSessionDependencies
    ) async {
        let options = await dependencies.migrationManager.migrationNetworkOptions(winnerAccountUUID)
        // R9-T7: tracks whether `stopSyncBeforeMigrationBroadcast()` ran THIS attempt — declared
        // outside the `do` so the `catch` clauses below can read it too (mirrors
        // `MigrationSendingStore.executeNextTransfer`'s identical `var` exactly). Nothing here can
        // return before reaching the call (the winning account is already resolved by the planner
        // before this function runs, unlike Sending's no-account/Keystone-dust/USK-derivation
        // guards), so it is unconditionally `true` once the `do` block is entered — tracked the same
        // way regardless, so the nudge checks below read identically at both call sites.
        var didStopSyncForBroadcast = false
        do {
            await dependencies.sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
            didStopSyncForBroadcast = true
            let result = try await dependencies.sdkSynchronizer.executeNextPendingMigrationTransfer(winnerAccountUUID, options)

            switch result {
            case .success:
                // [MOB-1496] W2: persist the sent record + reconcile (this op's success is one of
                // `reconcile()`'s triggers). R9-T7: no nudge — the SDK's own gate transition on a
                // successful broadcast already covers the resume (mirrors Sending's `.success` case).
                if let result {
                    await handleLandedBroadcast(winnerAccountUUID, result, classifications: classifications, dependencies: dependencies)
                }

            case .networkError, .invalidNote, .expired:
                if let result {
                    _ = await dependencies.migrationManager.routeBroadcastFailure(winnerAccountUUID, result: result)
                }
                let progress = (try? await dependencies.sdkSynchronizer.getMigrationProgress(winnerAccountUUID)) ?? nil
                let nextNumber = (progress?.completedTransfers ?? 0) + 1
                // R8-T5 (S4): attributed to the winning account this broadcast attempt was for.
                await dependencies.userNotifications.scheduleMigrationNotification(
                    MigrationNotification.transferWaiting(number: nextNumber),
                    nil,
                    Data(winnerAccountUUID.id).hexEncodedString()
                )
                await dependencies.migrationBGScheduler.scheduleNextWindow()
                // R9-T7: not landed — the stop above was never followed by a successful broadcast,
                // so nudge Root's gate feed directly (mirrors Sending's identical non-success nudge).
                if didStopSyncForBroadcast {
                    await dependencies.migrationManager.refreshMigrationSyncGate()
                }

            case nil:
                await dependencies.migrationBGScheduler.scheduleNextWindow()
                // R9-T7: nothing was due, but the stop above still ran — nudge exactly like
                // Sending's own `nil`-result case.
                if didStopSyncForBroadcast {
                    await dependencies.migrationManager.refreshMigrationSyncGate()
                }
            }
        } catch ZcashError.migrationRecordFailedAfterBroadcast(_) {
            // [MOB-1496] The broadcast DID land; only the engine's own recording of it failed —
            // route through the SAME handling as a `.success` result, with an unknown txId
            // (`MigrationScheduleStorage` maps an empty string to `nil`). The BG session must not
            // re-send (this isn't a networkError) and must not skip the notification/re-arm a
            // landed transfer deserves. Mirrors `MigrationSendingStore`/`MigrationNoteSplitStore`'s
            // identical foreground rationale for this same error. R9-T7: landed, so no nudge either
            // — matches Sending's identical catch clause (which never even checks the flag).
            await handleLandedBroadcast(
                winnerAccountUUID,
                MigrationTransferResult.success(txId: ""),
                classifications: classifications,
                dependencies: dependencies
            )
        } catch {
            // R7-T3 (MOB-1497): classify + route the thrown error too (e.g. `migrationTorUnavailable`
            // routes as Tor-class here) — same re-arm-only outward behavior as before; the route's
            // only effect is the possible embedded rotation (see this method's own doc). R9-T7: a
            // `ZcashError.migrationBroadcastDuringSync` race (the stop above narrows this window but
            // the guard stays only point-in-time) classifies to `nil` inside the
            // `routeBroadcastFailure(_:error:)` overload — see `MigrationBroadcastFailureClass
            // .classify(error:)`'s dedicated carve-out — so it never reaches the stateful routing
            // (nor the prompt latch below) at all.
            // T5 (MOB-1497): this executor is BACKGROUND-only — its single caller is
            // `runMigrationSession`'s `.broadcast` case, never a foreground path (foreground broadcasts
            // call `routeBroadcastFailure` directly from `MigrationSending`/`MigrationNoteSplitStore`).
            // So a Tor-class route HERE (R14 `.torFirstRunChoice` / R15 `.torHold`) latches the
            // per-account "pending background Tor prompt" flag for T6 to surface over Home on the next
            // foreground — arming it at THIS BG call site (rather than inside the shared
            // `routeBroadcastFailure`) is what keeps foreground failures, which have their own on-screen
            // UI, from ever arming it. The `.networkError`/`.invalidNote`/`.expired` result path above
            // can only ever classify as `.endpointUnreachable` (never a Tor route — see
            // `MigrationBroadcastFailureClass.classify(result:)`), so this thrown-error path is the only
            // place the flag can be armed.
            let route = await dependencies.migrationManager.routeBroadcastFailure(winnerAccountUUID, error: error)
            if route == MigrationBroadcastFailureRoute.torFirstRunChoice || route == MigrationBroadcastFailureRoute.torHold {
                await dependencies.migrationManager.setPendingBackgroundTorPrompt(winnerAccountUUID, true)
            }
            // A throwing broadcast attempt for any OTHER reason is not itself a definite outcome to
            // notify about — treat it like the `nil` "nothing executed" case: re-arm the next
            // window and let that session's own outcome (or the engine's self-heal) settle it,
            // without a possibly-wrong notification.
            LoggerProxy.error("BGTask migration session: executeNextPendingMigrationTransfer failed \(error)")
            await dependencies.migrationBGScheduler.scheduleNextWindow()
            // R9-T7: not landed — nudge exactly like Sending's own generic-catch nudge. Fires here
            // too for the nil-classified during-sync race above: the stop still ran and this attempt
            // still never landed, so sync must still resume.
            if didStopSyncForBroadcast {
                await dependencies.migrationManager.refreshMigrationSyncGate()
            }
        }
    }

    /// [MOB-1496] Shared by the `.success` outcome and the
    /// `ZcashError.migrationRecordFailedAfterBroadcast` catch clause above — the broadcast landed
    /// either way (only the engine's own recording of it failed in the latter case), so both paths
    /// persist the sent record, reconcile, and notify/re-arm (or cancel-on-complete) identically.
    /// Mirrors the same rationale `MigrationSendingStore`/`MigrationNoteSplitStore` already apply
    /// for their own foreground broadcasts. Parameterized by `accountUUID` — the session's single
    /// winning account, not necessarily the selected one (MOB-1496 W5).
    ///
    /// Fix-wave finding 1 (review IMPORTANT-1): the winner completing must NOT `cancelAll`/announce
    /// `.migrationComplete` while another classified account still has an active run — only when
    /// EVERY OTHER account this session already classified is ALSO done
    /// (`MigrationSessionPlanner.allAccountsAreDone`, the SAME predicate `plan(_:)` uses for its own
    /// `.cancelAll` gate, reused here so the two sites cannot drift) does this cancel/notify-
    /// complete. An empty "other accounts" list (the single-account case) is vacuously done,
    /// preserving the original single-account complete->cancelAll behavior exactly. `.unreadable`
    /// never counts as done (see `isDoneClassification`), so one unreadable account blocks a
    /// premature cancelAll too.
    ///
    /// MOB-1496: `MigrationState.complete` is per-RUN now, never "the whole migration is done" —
    /// the final engine caps how much a single run covers (a per-run cap, or funds arriving
    /// mid-run), so this landed broadcast completing the STORED run may still leave more to
    /// migrate. `isMigrationRemainderPending` below reflects the once-per-transition evaluation
    /// `reconcile()` (just above) already ran for this exact `.complete` transition — see
    /// `MigrationManagerImpl.evaluateMigrationRemainder`'s doc for why it runs there and not here
    /// (a fresh propose on every landed broadcast would race a commit the user is mid-review of).
    /// Non-empty fires `.migrationBatchComplete` instead of `.migrationComplete`; `cancelAll()`
    /// still runs in BOTH cases — nothing is broadcastable until the user consents to a NEW run
    /// (even one with more to migrate), and that run's own confirm/commit is what re-arms
    /// scheduling. A `nil`-evaluated flag (the in-`reconcile()` propose itself threw) reads as
    /// `false` and fires `.migrationComplete` — accepted, since the banner/flag both self-heal on a
    /// later reconcile once the propose eventually succeeds.
    private static func handleLandedBroadcast(
        _ accountUUID: AccountUUID,
        _ result: MigrationTransferResult,
        classifications: [(accountUUID: AccountUUID, classification: MigrationAccountClassification)],
        dependencies: MigrationSessionDependencies
    ) async {
        await dependencies.migrationManager.recordTransferBroadcast(accountUUID, result)
        // MOB-1496: this is also where the once-per-transition remainder evaluation runs (inside
        // `MigrationManagerImpl.reconcile()`) — by the time this call returns,
        // `isMigrationRemainderPending` below already reflects a fresh propose if this broadcast
        // just moved the account into `.complete` for the first time.
        await dependencies.migrationManager.reconcile()

        let migrationState = try? await dependencies.sdkSynchronizer.getMigrationState(accountUUID)
        let otherAccounts = classifications.filter { $0.accountUUID != accountUUID }
        let everyOtherAccountDone = MigrationSessionPlanner.allAccountsAreDone(otherAccounts)

        // R8-T5 (S4): both branches below attribute to `accountUUID` — the account whose broadcast
        // just landed, which is what either notification is actually reporting on.
        let accountUUIDString = Data(accountUUID.id).hexEncodedString()

        if migrationState == MigrationState.complete && everyOtherAccountDone {
            let remainder = dependencies.migrationManager.isMigrationRemainderPending(accountUUID)
            let notification = remainder ? MigrationNotification.migrationBatchComplete : MigrationNotification.migrationComplete
            await dependencies.userNotifications.scheduleMigrationNotification(notification, nil, accountUUIDString)
            // Nothing is broadcastable until the user consents to a new run, whether or not more
            // remains — that new run's own confirm/commit re-arms scheduling.
            await dependencies.migrationBGScheduler.cancelAll()
        } else {
            let notification = await Self.transferCompleteNotification(accountUUID: accountUUID, sdkSynchronizer: dependencies.sdkSynchronizer)
            await dependencies.userNotifications.scheduleMigrationNotification(notification, nil, accountUUIDString)
            await dependencies.migrationBGScheduler.scheduleNextWindow()
        }
    }

    /// Builds the `.transferComplete` notification payload from the freshly-updated migration
    /// state: `number`/`total`/`remaining` from `getMigrationProgress()`, `nextInHours` from the
    /// same cadence-window derivation `MigrationBGSchedulerClient`'s `arm(margin:)` uses (§8.3's
    /// next-window margin, `estimateTimestamp` as the preferred source), rounded to hours.
    private static func transferCompleteNotification(
        accountUUID: AccountUUID,
        sdkSynchronizer: SDKSynchronizerClient
    ) async -> MigrationNotification {
        // Flatten the `try?`-around-an-Optional-returning-throwing-function double-optional
        // (`MigrationProgress??`) down to a plain `MigrationProgress?` — a read failure and "no
        // progress in flight" both mean the same thing to this notification (fall back to 0/0/zero).
        let progressResult = try? await sdkSynchronizer.getMigrationProgress(accountUUID)
        let progress = progressResult ?? nil

        let preferredExecutableAt = progress?.nextTransferReadyAtHeight.flatMap { height in
            sdkSynchronizer.estimateTimestamp(height).map { Date(timeIntervalSince1970: $0) }
        }
        let now = Date()
        let window = MigrationCadence.window(
            margin: MigrationCadence.nextWindowMargin,
            preferredExecutableAt: preferredExecutableAt,
            now: now
        )
        let nextInHours = Int((window.timeIntervalSince(now) / 3600).rounded())

        return MigrationNotification.transferComplete(
            number: progress?.completedTransfers ?? 0,
            total: progress?.totalTransfers ?? 0,
            nextInHours: nextInHours,
            remaining: progress?.remainingOrchard ?? Zatoshi.zero
        )
    }

    // MARK: - R8-T6 fix-wave (Critical-1): send-wait hold release on external flow teardown

    /// `migrationSendWaitActive` (the `.retryStart` fence flag set/cleared around
    /// `MigrationSendingStore`'s send-now WAITING phase — see the `.retryStart` proactive check
    /// above) is a process-global `@Shared(.inMemory(...))`. The ONLY clears that flag from
    /// INSIDE the flow are `MigrationSendingStore`'s own `.sendNowGateResolved(.allowed)` and
    /// `.waitCancelTapped` handlers — both require the `.sending(.waiting)` element to still be
    /// alive and to run its own exit. An external teardown (Root discarding/replacing the
    /// migration flow's state from OUTSIDE that store — e.g. a migration-notification tap
    /// resetting the flow via `openMigrationCoordFlow` below, or the flow being popped out from
    /// under it) bypasses those exits entirely: the flag is stranded `true` forever, and every
    /// future `.retryStart` silently re-defers (permanent silent sync stop — see this fix-wave's
    /// report for the full trace).
    ///
    /// Called at every such external-teardown site, BEFORE the reset/pop itself. Safe to call
    /// unconditionally: a no-op (no nudge) when the flag isn't set. When it IS set, clears it and
    /// ALWAYS fires the SAME `refreshMigrationSyncGate()` nudge `.waitCancelTapped` already uses,
    /// so the existing `.migrationSyncGateChanged` resume machinery (above) restarts sync exactly
    /// as if the user had tapped Cancel themselves.
    ///
    /// R8 final cumulative review (Finding 1): the nudge used to be gated on
    /// `migrationStoppedSyncForBroadcast` ALSO being set — but that flag can be legitimately
    /// consumed WHILE the hold is still live: an UNRELATED `.migrationSyncGateChanged(false)`
    /// (e.g. a different lane's failure nudge, or a prior broadcast's SDK gate expiring mid-wait)
    /// satisfies `shouldResume` purely off `migrationStoppedSyncForBroadcast`, clears THAT flag,
    /// and replays `.retryStart` — which re-defers on the still-live hold and sets
    /// `syncDeferredByMigrationGate`. A helper that only nudges when `migrationStoppedSyncForBroadcast`
    /// is (still) set would then find it already `false` and skip the nudge — stranding
    /// `syncDeferredByMigrationGate` with no future `.migrationSyncGateChanged` arrival left to
    /// consume it (sync stays stopped until the next foreground event). The nudge is now
    /// unconditional on clearing a LIVE hold, independent of either flag's value: it re-pushes the
    /// current gate reading, and `.migrationSyncGateChanged`'s `shouldResume` already handles BOTH
    /// `syncDeferredByMigrationGate` and `migrationStoppedSyncForBroadcast` — whichever (if either)
    /// is actually stranded gets consumed by this one nudge. A spurious nudge when NEITHER flag is
    /// stranded is a genuine no-op: with no real SDK gate transition (`isGenuineChange` false) and
    /// both flags already clear (`shouldResume` false), `.migrationSyncGateChanged`'s own guard
    /// (`isGenuineChange || shouldResume`) returns `.none` before touching any state — so this can
    /// never manufacture a spurious resume/reconcile out of nothing.
    func releaseSendWaitHold() -> Effect<Root.Action> {
        @Shared(.inMemory(.migrationSendWaitActive)) var migrationSendWaitActive: Bool = false
        guard migrationSendWaitActive else { return .none }

        $migrationSendWaitActive.withLock { $0 = false }

        return .run { [migrationManager] _ in await migrationManager.refreshMigrationSyncGate() }
    }

    // MARK: - MOB-1496: Keystone migration-run abandon reconciliation on external flow teardown

    /// Mirrors `releaseSendWaitHold()`'s placement above for a DIFFERENT external-teardown hazard:
    /// the final migration engine creates a Keystone commit's ENTIRE run — preparation (note-split)
    /// transactions and the schedule's own transfers alike — the moment its PCZTs are built
    /// (`SDKSynchronizerClient.proposeNoteSplitPCZTs`, called unconditionally by
    /// `MigrationCommitPipeline.proposeKeystoneBatch`), and always resumes a stored non-terminal run
    /// on the next attempt, ignoring any newer preview (see `SDKSynchronizerInterface`'s doc). If
    /// `state.migrationCoordFlowState` is torn down here — from OUTSIDE the flow, the same class of
    /// site `releaseSendWaitHold()` guards — while a Keystone ceremony (`pendingKeystoneSigning`) is
    /// still live, the run it already built is left stranded: a later re-entry would silently resume
    /// signing those same, by-then-stale PCZTs instead of proposing a fresh preview.
    ///
    /// `pendingKeystoneSigning` is only ever set once its PCZTs successfully built (see
    /// `MigrationCoordFlowCoordinator`'s three setters), so its presence here is exactly "a PCZT batch
    /// was proposed and never resolved" — cancel it via `restartCurrentMigrationStep`, discarding the
    /// fresh schedule it returns (the user re-runs the ceremony from a fresh preview on their next
    /// attempt — same v1 semantics as `MigrationCoordFlowCoordinator.keystoneScanAbandoned`'s in-flow
    /// twin). Read BEFORE the caller resets/replaces `migrationCoordFlowState`. Fire-and-forget: a
    /// failure here just leaves the stray run for the next attempt to encounter and cancel itself,
    /// same as today.
    func cancelAbandonedKeystoneMigrationRun(state: Root.State) -> Effect<Root.Action> {
        guard state.migrationCoordFlowState.pendingKeystoneSigning != nil,
              let accountUUID = state.selectedWalletAccount?.id else {
            return .none
        }

        return .run { [sdkSynchronizer] _ in
            _ = try? await sdkSynchronizer.restartCurrentMigrationStep(accountUUID, false)
        }
    }

    // MARK: - MOB-1467: Migration notification-tap deep link

    /// Exactly the SmartBanner-tap routing (`RootCoordinator`'s
    /// `.home(.smartBanner(.migrationScreenRequested))`): fresh flow state, open the migration
    /// path. Shared by the immediate (Home already up) and deferred (fired from
    /// `checkBackupPhraseValidation` once initialization reaches Home) call sites, and by
    /// `.migrationNotificationRoute` below.
    ///
    /// R8-T6 fix-wave (Critical-1): this is itself an external-teardown site (a live
    /// `.sending(.waiting)` element may be sitting under the flow state this wholesale-replaces —
    /// the migration-notification tap does not require the migration flow to be closed first) —
    /// `releaseSendWaitHold()` runs BEFORE the reset. MOB-1496: same reasoning applies to a live
    /// Keystone signing ceremony — `cancelAbandonedKeystoneMigrationRun(state:)` also runs BEFORE the
    /// reset, reading `pendingKeystoneSigning` off the ABOUT-TO-BE-DISCARDED state.
    private func openMigrationCoordFlow(state: inout Root.State) -> Effect<Root.Action> {
        let releaseEffect = releaseSendWaitHold()
        let cancelEffect = cancelAbandonedKeystoneMigrationRun(state: state)
        state.migrationCoordFlowState = MigrationCoordFlow.State.initial
        state.path = Root.State.Path.migrationCoordFlow
        return .merge(releaseEffect, cancelEffect)
    }

    /// R8-T5 (S4): `accountUUID` is the tapped notification's payload account (hex-encoded, matching
    /// every compose site's own `Data.hexEncodedString()` encoding). When it resolves to a wallet
    /// account that ISN'T already selected, that account is switched to FIRST — via the house
    /// account-switch action (`.home(.walletAccountTapped(_:))`, the SAME one `WalletAccountsSheet`'s
    /// tap uses; `RootCoordinator`'s handler does the real work: the `@Shared` write plus balance/
    /// contacts/metadata refresh, never hand-rolled here) — THEN the flow opens.
    /// `.concatenate` orders the two dispatches so the switch action's reducer pass (the synchronous
    /// `@Shared` write) is fully applied before `.migrationNotificationRoute` opens the flow — see
    /// `RootMigrationRoutingTests.migrationNotificationTappedWithDifferentAccountSwitchesBeforeRouting`'s
    /// own doc for why that test verifies the OUTCOME rather than empirically proving the order
    /// (`TestStore` would be the tool for that, but it requires `Root.State: Equatable`, which it
    /// isn't). A nil/unresolvable/already-selected payload skips the switch and opens the flow
    /// immediately in this SAME pass, exactly as before S4.
    private func migrationNotificationTappedRoutingEffect(
        state: inout Root.State,
        accountUUID: String?
    ) -> Effect<Root.Action> {
        if let accountUUID,
           let targetAccount = state.walletAccounts.first(where: { Data($0.id.id).hexEncodedString() == accountUUID }),
           targetAccount != state.selectedWalletAccount {
            return .concatenate(
                .send(.home(.walletAccountTapped(targetAccount))),
                .send(.initialization(.migrationNotificationRoute))
            )
        }

        return openMigrationCoordFlow(state: &state)
    }
}
