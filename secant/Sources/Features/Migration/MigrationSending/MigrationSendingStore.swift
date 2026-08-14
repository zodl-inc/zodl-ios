//
//  MigrationSendingStore.swift
//  zodl
//
//  "Sending" / "Sent" screen (MOB-1463, Figma S8 · sending 2618:6858 / sent 2618:6895). Shown while
//  a migration transfer broadcasts — the immediate confirm lane — then flips to a
//  success state once that one transfer has been executed. `onAppear` runs the immediate sweep's
//  own submission (`MigrationCommitPipeline.commitImmediateSoftware`), recording a broadcast on
//  success; a failure/`nil` result presents the failure sheet, and `retryTapped` re-runs the same
//  step (MOB-1466). 2026-08-07: the SCHEDULED-RUN delivery branch that also lived here — ask the
//  manager for a `.broadcast` instruction, then `performMigrationBroadcast` it — is GONE with the
//  client member that fed it; instructions are issued by the drive and flow one way, and a screen
//  that asks for one is the crank-and-filter the design forbids. It had no reachable producer.
//
//  2026-08-07 (Lukas): the SEND-NOW and MANUAL-DELIVERY lanes this screen also served are GONE —
//  "send is driven only by .broadcast(id) next_step, never waiting on manual tap." With them went
//  `entersViaSendNow`, the `.waiting(target:)` phase + its `sendGate()` wait machinery, the
//  `migrationSendWaitActive` fence, and `isManualStepLane` (the "sent to Ironwood" subtitle fork —
//  the hidden "sent" Success frame 3491:11750 is now frame-only; its key stays in the catalog).
//
//  MOB-1496 (W5, ZIP-0318 MUST): a background session — and this screen's own executor — may
//  broadcast at most ONE overdue transfer. `totalCount`/`sentCount` remain (informational), but
//  `.transferResult`'s success handler no longer loops back into `executeNextTransfer` — a single
//  success always finishes the screen. Remaining overdue transfers stay scheduled; the driver's
//  open/tick lanes pick them up. The `closeTapped` / `viewTransactionTapped` delegates are
//  consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  This same screen was reused for the "Migrate anyway" dust lane (MOB-1487) via a dedicated
//  `isDustLane` execution branch (a USK composite, `migrateMigrationDust`, that re-proposed a
//  residual-inclusive schedule from scratch). MOB-1496 (W-B): retired — "Migrate anyway" now rides
//  the SAME immediate (`immediateProposal`)/Keystone-ceremony lanes as the entry-screen migration;
//  the coordinator resolves the proposal (or a propose/unlock failure) BEFORE ever pushing this
//  screen, so there is no dust-specific branch left here at all. `isDustLane` never drove any
//  on-screen copy (MOB-1494 round 4 already unified every lane's wording), so nothing user-visible
//  changes.
//
//
//  MOB-1513 (Lane A2 — send-max immediate migration): `immediateProposal`, threaded by the
//  coordinator's `.reviewTransfer(.delegate(.confirmed))` handler for a SOFTWARE immediate-mode
//  confirm (Keystone's immediate lane never reaches this screen mid-broadcast — its actual submit
//  already happened in the coordinator's post-signing step by the time `MigrationSending` is pushed;
//  see `MigrationCoordFlowCoordinator.submitImmediateKeystoneTransaction`), marks the ONLY lane where
//  `onAppear`'s broadcast genuinely completes the whole migration plan in one shot — every other
//  lane's single successful broadcast finishes THIS SCREEN (MOB-1496 W5 above) but the overall
//  migration run may still have more scheduled transfers left; the immediate lane has none by
//  construction (a send-max proposal is exactly one transaction). `executeNextTransfer` derives the
//  account's USK (same hoisted-above-the-broadcast treatment the dust lane's own derivation gets —
//  R9-T4 finding 5) and calls `MigrationCommitPipeline.commitImmediateSoftware`
//  (`createAndSubmitProposedTransactions`, already transaction-guarded in `SDKSynchronizerLive`)
//  instead of `performMigrationBroadcast` — the immediate proposal is engine-external, so
//  there is nothing stored in the engine for that call to serve. This deliberately does NOT ride the
//  engine transfers' `MigrationBroadcaster` Tor-first multi-endpoint routing
//  (`performMigrationBroadcast`'s own delivery mechanism) — the immediate sweep rides the
//  standard ordinary-send submission path by design (the Tor consent sheet upstream, at Entry/How
//  This Works, still gates the flow before this screen is ever reached, so the user's Tor choice is
//  respected identically either way; only the BROADCAST plumbing underneath differs). Success is
//  still keyed to the actual submit outcome exactly like every other lane, never to `migrationMode`.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationSending {
    @ObservableState
    struct State: Equatable {
        enum Phase: Equatable {
            case sending
            // (`.waiting(target:)` — the send-now lane's gate countdown — was REMOVED 2026-08-07
            // with the manual-tap send surface.)
            case success
        }

        var phase = Phase.sending
        /// Failure sheet presented over the sending phase.
        var isFailurePresented = false
        /// R7-T3 (MOB-1497): the classified/routed variant of the presented failure sheet — `nil`
        /// keeps the existing generic copy (an unclassified failure, or R16's `.retryRotated`/
        /// `.plainRetry`, both of which reuse the existing sheet verbatim since the rotation itself
        /// is silent). Set by `.broadcastFailureRouted`, which always arrives (when it arrives at
        /// all) immediately before the `.transferResult` that flips `isFailurePresented` — see
        /// `executeNextTransfer`'s doc.
        var failureKind: MigrationBroadcastFailureRoute?
        @Presents var alert: AlertState<Action>?
        /// The most recently broadcast transfer's tx id (wires up View Transaction).
        var txId = ""
        /// MOB-1496 (W5, ZIP-0318): informational only — `onAppear` always executes AT MOST ONE
        /// transfer regardless of this value. Coordinator-configured (always 1 today).
        var totalCount = 1
        /// 0 before a send, 1 after — this screen never executes more than one transfer (MOB-1496 W5).
        var sentCount = 0
        /// MOB-1513: the immediate lane's send-max proposal — see this file's header doc. Non-`nil`
        /// for a SOFTWARE immediate-mode confirm OR software "Migrate anyway" (MOB-1496 W-B).
        ///
        /// 2026-08-07: it is now REQUIRED for this screen to execute anything. The Keystone lane
        /// pushes this screen already in `.success` (its broadcast happened in the coordinator),
        /// and the scheduled lane no longer reaches this screen at all, so a `nil` proposal means
        /// simply "nothing to submit" — reported as a `nil` result.
        var immediateProposal: ImmediateMigrationProposal?
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        /// The success phase's subtitle — "...migrated to Ironwood." (The manual lane's "...sent
        /// to Ironwood." fork retired 2026-08-07 with `isManualStepLane`; the designed hidden
        /// Success frame `3491:11750` and its key stay in Figma/the catalog, frame-only.)
        var sentSubtitle: String {
            String(localizable: .migrationSendingSentSubtitleMigrated)
        }

        init(
            phase: Phase = .sending,
            isFailurePresented: Bool = false,
            txId: String = "",
            totalCount: Int = 1,
            sentCount: Int = 0,
            immediateProposal: ImmediateMigrationProposal? = nil
        ) {
            self.phase = phase
            self.isFailurePresented = isFailurePresented
            self.txId = txId
            self.totalCount = totalCount
            self.sentCount = sentCount
            self.immediateProposal = immediateProposal
        }
    }

    enum Action: BindableAction, Equatable {
        /// The screen's one transfer has been successfully broadcast (MOB-1496 W5: never more than
        /// one, regardless of `totalCount`).
        case allTransfersSent
        case alert(PresentationAction<Action>)
        case binding(BindingAction<State>)
        /// R7-T3 (MOB-1497, R14/R15/R16): `routeBroadcastFailure`'s resolved route for a classified
        /// broadcast failure — sets `state.failureKind`, presented by the immediately-following
        /// `.transferResult` (see `executeNextTransfer`'s doc). Never sent for an unclassified
        /// failure — `failureKind` then stays `nil`, the existing generic sheet.
        case broadcastFailureRouted(MigrationBroadcastFailureRoute)
        /// Failure sheet: dismiss (stay on screen).
        case cancelTapped
        case closeTapped
        case delegate(Delegate)
        /// R7-T3 (R11, reused from `MigrationTorSheet`'s off-warning): the R14 sheet's "Proceed
        /// without Tor" alert confirms — turns Tor off for the REST of this run then retries.
        case offWarningProceedTapped
        case onAppear
        /// R7-T3 (R14): the `.torFirstRunChoice` sheet's "Proceed without Tor" button — presents the
        /// R11 warning alert instead of proceeding directly.
        case proceedWithoutTorTapped
        /// Failure sheet: dismiss, then re-run the failed step.
        case retryTapped
        /// The immediate submission's result for the current step; `nil` on a stub/no-op, or when
        /// there was nothing to submit.
        case transferResult(MigrationTransferResult?)
        /// R7-T3 (R17): the `.providerExhausted` sheet's "Broadcast via sync server" button.
        case useSyncServerTapped
        case viewTransactionTapped
        // (`sendNowGateResolved` / `waitCancelTapped` / `waitFired` — the send-now lane's gate
        // machinery — were REMOVED 2026-08-07 with the manual-tap send surface.)

        enum Delegate: Equatable {
            case closed
            case viewTransaction
        }
    }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .allTransfersSent:
                state.phase = .success
                return .none

            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                // Mirrors `MigrationCompleteStore`'s plain shape (not `MigrationTorSheetStore`'s,
                // which additionally resets its own `isTorOn` toggle) — this screen has no toggle
                // analog to restore; "Keep Tor on" simply returns to the R14 sheet unchanged.
                state.alert = nil
                return .none

            case .binding:
                return .none

            case .broadcastFailureRouted(let route):
                // WHY it failed. The sheet says "The transaction couldn't be broadcast" and nothing
                // more, which is right for a user and useless for a tester — a repeated failure was
                // indistinguishable from a different failure each time.
                LoggerProxy.event("\(MigrationManagerImpl.logTag) send screen: broadcast failed — route \(route)")
                state.failureKind = route
                return .none

            case .cancelTapped:
                // Cancel must LEAVE the screen, not merely dismiss the sheet. `.sending` renders a
                // Lottie and two labels and NOTHING else — no button, no back affordance — so
                // dismissing in place stranded the user on a progress screen that could never
                // progress, and the only way out was killing the app. Field-caught 2026-07-31,
                // during a real broadcast failure, which is exactly when a user is least willing to
                // believe that force-quitting a wallet is safe.
                state.isFailurePresented = false
                state.failureKind = nil
                return .send(.delegate(.closed))

            case .closeTapped:
                return .send(.delegate(.closed))

            case .delegate:
                return .none

            case .offWarningProceedTapped:
                state.alert = nil
                state.isFailurePresented = false
                state.failureKind = nil
                let account = state.selectedWalletAccount
                if let account {
                    migrationManager.overrideTorForRun(account.id, false)
                }
                return executeNextTransfer(account: account, immediateProposal: state.immediateProposal)

            case .onAppear:
                // A screen pushed ALREADY showing a failure has nothing to execute — the failure
                // happened before this screen appeared.
                //
                // NO PRODUCTION PUSH DOES THIS ANY MORE (2026-08-07). The one that did was the
                // Keystone immediate lane's `.keystoneImmediateSubmitFailed` fallback, taken when
                // the Review element was gone after the scan/sign pop; it now pushes a fresh
                // immediate Review with the commit-failure sheet instead, so Retry re-attempts the
                // ceremony that actually failed rather than driving the scheduled lane. (The
                // comment here used to attribute this state to the "Migrate anyway"
                // propose/unlock failure. That was never true: `.migrateAnywayUnlocked` pushes a
                // Review, and `.migrateAnywayFailed` only clears the Complete screen's spinner —
                // neither ever pushed this screen.)
                //
                // The guard stays as a belt: the initializer still takes `isFailurePresented`
                // (the view's preview uses it), and executing under an already-open failure sheet
                // would be wrong for any future producer.
                guard !state.isFailurePresented else { return .none }
                // MOB-1513 (R10): a screen pushed ALREADY in `.success` (the Keystone immediate lane —
                // its broadcast happens in the coordinator BEFORE this screen is pushed) has nothing to
                // execute either — re-running the executor here hit the engine's "nothing pending" path
                // and popped the failure sheet over the success screen (the QA-reported bogus error).
                if case .success = state.phase { return .none }
                return executeNextTransfer(account: state.selectedWalletAccount, immediateProposal: state.immediateProposal)

            case .proceedWithoutTorTapped:
                // R7-review fix (Minor-3): gated to the R14 first-run-choice variant — the alert this
                // presents leads to a clearnet retry (`overrideTorForRun(account, false)`), which R15's
                // mid-run hold must never offer. The view already never renders this button outside
                // `.torFirstRunChoice`; this closes the same gap at the reducer, where it actually
                // matters (a raw `.send`/programmatic dispatch bypasses the view entirely).
                guard state.failureKind == MigrationBroadcastFailureRoute.torFirstRunChoice else { return .none }
                let usesFullBalanceCopy = migrationManager.migrationMode(state.selectedWalletAccount?.id) == MigrationMode.immediate
                state.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: usesFullBalanceCopy, proceedAction: .offWarningProceedTapped)
                return .none

            case .retryTapped:
                state.isFailurePresented = false
                state.failureKind = nil
                return executeNextTransfer(account: state.selectedWalletAccount, immediateProposal: state.immediateProposal)

            case .useSyncServerTapped:
                state.isFailurePresented = false
                state.failureKind = nil
                guard let account = state.selectedWalletAccount else { return .none }
                return .concatenate(
                    .run { [migrationManager] _ in await migrationManager.overrideBroadcastEndpointToSyncServer(account.id) },
                    executeNextTransfer(account: account, immediateProposal: state.immediateProposal)
                )

            case .transferResult(let result):
                switch result {
                case .success(let txId):
                    state.txId = txId
                    state.sentCount += 1

                    // MOB-1496 (W5, ZIP-0318 MUST): a single successful broadcast always finishes
                    // this screen — never chain into another `executeNextTransfer` call, regardless
                    // of `totalCount` (the "send now" push site's overdue-row count is informational
                    // only now). Remaining overdue transfers stay scheduled; the next background
                    // window (armed by `scheduleNextWindow()` below) or a separate, explicit "Send
                    // now" tap picks them up.
                    //
                    // PHASE 3: #1930 ran `migrationBGScheduler.scheduleNextWindow()` as the middle
                    // effect here. That dependency does not exist in this build — plan D2 reversed
                    // the background lane (iOS grants ~1-2 BG fires/24 h), so there is no BG task to
                    // re-arm. Its OTHER half — arming the next window's local notifications — is
                    // Phase 4, and lands back in exactly this position.
                    //
                    // MOB-1496: `reconcile()` runs here so `migrationManager.stateEvents` picks up
                    // the just-completed transfer promptly (a store completing a migration op is one
                    // of `reconcile()`'s two triggers). MOB-1496 (W2): `recordTransferBroadcast`
                    // persists the sent record the SDK itself no longer retains — runs BEFORE
                    // `reconcile()` so the freshly reconciled state is observed alongside an
                    // already-updated schedule. Order is load-bearing; keep the concatenate.
                    return .concatenate(
                        .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] _ in
                            await migrationManager.recordTransferBroadcast(accountUUID, MigrationTransferResult.success(txId: txId))
                        },
                        .run { [migrationManager] _ in await migrationManager.reconcile() },
                        .send(.allTransfersSent)
                    )

                case .networkError, .invalidNote, .expired, nil:
                    state.isFailurePresented = true
                    return .none
                }

            case .viewTransactionTapped:
                return .send(.delegate(.viewTransaction))
            }
        }
    }

    /// This is `MigrationCommitPipeline.commitImmediateSoftware`'s ONLY foreground executor with
    /// failure UX (R7-T3 §6 disposition). The dedicated
    /// `ZcashError.migrationRecordFailedAfterBroadcast` catch that stood between the `do` and the
    /// generic catch below left 2026-08-08 as dead code: it served the DELETED scheduled-run
    /// delivery arm — `performMigrationBroadcast`, whose record step can throw it (the SDK's only
    /// throw site is `OrchardMigration.broadcastAndRecord`, reachable solely through
    /// `performMigrationBroadcast`/`submitNoteSplit`) — while the immediate lane's whole pipeline
    /// (`createAndSubmitProposedTransactions` -> the raw multi-server submit, with
    /// `recordImmediateMigration` wrapped in its own never-throwing best-effort catch) never
    /// touches the engine's record path at all. The arm had also gone WRONG in place: it skipped
    /// the `refreshMigrationSyncGate()` nudge on a path where `stopSyncBeforeMigrationBroadcast()`
    /// had already run — its justification (the engine's own gate transitioned on the record)
    /// left with the engine lane — so had it ever been hit, no path would have restarted sync for
    /// the rest of the foreground session. Were the error somehow thrown again, the generic catch
    /// handles it soundly: `classify(error:)` deliberately maps it to no route, and the nudge
    /// fires because sync WAS stopped.
    ///
    /// R9-T4 (MOB-1497 review remediation, finding 5): the immediate lane's USK derivation is
    /// hoisted ABOVE the broadcast `do`/`catch` below, in its own `do`/`catch` — see the hoist's
    /// inline comment for the full rationale. A derivation failure sends the SAME
    /// `.transferResult(nil)` the broadcast `do`/`catch`'s generic catch sends for an unrouted
    /// failure, but WITHOUT ever calling `routeBroadcastFailure` or `refreshMigrationSyncGate`: no
    /// broadcast was attempted, so neither applies.
    ///
    /// R7-T3 (MOB-1497): every failure path below — the transport-outcome switch's failure branch AND
    /// the generic catch — classifies+routes (R9-T2: via `migrationManager.routeBroadcastFailure(_:
    /// result:/error:)`, the single classify -> route entry point) before sending its existing outcome
    /// action. A `nil` route (an unclassified failure — `.invalidNote`/`.expired`/
    /// `.networkError(retryable: false)`, or the "no account" guard above/the hoisted derivation
    /// failure, none of which reach the SDK call at all) keeps today's behavior byte-for-byte: only
    /// `.transferResult` is sent. A non-nil route ADDITIONALLY sends `.broadcastFailureRouted(route)`
    /// FIRST — the existing `.transferResult`/`isFailurePresented = true` handling is otherwise
    /// unchanged, so `state.failureKind` is always set before the sheet appears.
    ///
    /// Deliberately NO `[migrationManager]` capture on the `.run` below (unlike the reducer's own
    /// `.transferResult` success handler): the hoisted-derivation early-return guard inside this
    /// SAME closure must reach `send(.transferResult(nil))` without ever resolving
    /// `migrationManager` — an explicit capture evaluates (and, in a test with no override for ANY
    /// member, traps) at closure-CREATION time, before the guard even runs. Implicit capture defers
    /// resolution to the first line that actually touches `migrationManager`, exactly where the
    /// guard needs it to.
    private func executeNextTransfer(
        account: WalletAccount?,
        immediateProposal: ImmediateMigrationProposal?
    ) -> Effect<Action> {
        // IMMEDIATE-LANE ONLY (2026-08-07). The scheduled-run delivery branch that used to live
        // below — ask the manager for a `.broadcast` instruction, then submit it — is GONE, with
        // the client member that fed it. Instructions are issued by the drive and flow one way,
        // crank -> executor; a screen that ASKS for one is the banned crank-and-filter whatever
        // layer it sits in. Nothing was lost: the branch had no reachable producer. Every
        // production push that reaches this executor is the software immediate sweep
        // (`MigrationCoordFlowCoordinator`'s `.reviewTransfer(.delegate(.confirmed))`, whose own
        // comment records that the proposal is guaranteed populated there); the two `.success`
        // pushes short-circuit in `onAppear`, and the `.immediateReview` arm of
        // `resumeCommittedMigrationChain` is documented unreachable.
        //
        // So a missing account or proposal is now simply nothing to submit, reported as `nil`
        // exactly as an unusable account already was.
        guard let account, let immediateProposal else {
            return .run { send in await send(.transferResult(nil)) }
        }

        return .run { send in
            // MOB-1513: the immediate lane's USK derivation is pre-broadcast LOCAL work (keychain
            // export + derivation, `MigrationSpendingKeyDerivation.deriveUSK`) — hoisted ABOVE the
            // broadcast `do`/`catch` below so a failure here can never reach `routeBroadcastFailure`:
            // `MigrationBroadcastFailureClass.classify(error:)`'s default arm assumes every throw it
            // sees is a post-Tor-bootstrap connect/submit failure (see that type's doc), which a
            // keychain/derivation error is not. `stopSyncBeforeMigrationBroadcast()` stays below,
            // unchanged, so a hoisted failure here also never nudges `refreshMigrationSyncGate()` —
            // sync was never stopped for this attempt. `immediateProposal` is `nil` for every lane
            // except a software immediate-mode confirm (see `State.immediateProposal`'s doc), so
            // this is a no-op everywhere else.
            guard account.vendor != WalletAccount.Vendor.keystone, let zip32AccountIndex = account.zip32AccountIndex else {
                await send(.transferResult(nil))
                return
            }
            let immediateUSK: UnifiedSpendingKey
            do {
                immediateUSK = try await MigrationSpendingKeyDerivation.deriveUSK(
                    zip32AccountIndex: zip32AccountIndex,
                    walletStorage: walletStorage,
                    mnemonic: mnemonic,
                    derivationTool: derivationTool,
                    networkType: zcashSDKEnvironment.network().networkType
                )
            } catch {
                await send(.transferResult(nil))
                return
            }

            // MOB-1496 (R8-T4, #3): tracks whether `stopSyncBeforeMigrationBroadcast()` actually ran
            // THIS attempt — only a stop that was never followed by a successful broadcast needs the
            // nudge (see `migrationManager.refreshMigrationSyncGate`'s doc); the guards above (no
            // account / hoisted USK derivation) return before ever stopping sync, so they must not
            // nudge.
            var didStopSyncForBroadcast = false
            do {
                // MOB-1513: no `migrationNetworkOptions` read here by design — the immediate
                // lane's `createAndSubmitProposedTransactions` is the ordinary-send submission
                // path (endpoint selection via `userStoredPreferences.automaticServerSelection()`),
                // not the engine transfers' `MigrationNetworkPrivacyOptions`/Tor-first
                // `MigrationBroadcaster` routing — see this file's header doc for the accepted
                // divergence. Still stops sync first, consistent with every other foreground
                // migration broadcast lane.
                await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
                didStopSyncForBroadcast = true
                let txId = try await MigrationCommitPipeline.commitImmediateSoftware(
                    proposal: immediateProposal,
                    usk: immediateUSK,
                    accountUUID: account.id,
                    sdkSynchronizer: sdkSynchronizer
                )
                let result = MigrationTransferResult.success(txId: txId)
                if let route = await migrationManager.routeBroadcastFailure(account.id, result: result) {
                    await send(.broadcastFailureRouted(route))
                }
                await send(.transferResult(result))
                // MOB-1513: the immediate lane's success came from
                // `createAndSubmitProposedTransactions` (the ordinary-send submission path), which
                // never touches the ENGINE's own migration-sync privacy gate at all — unlike the
                // engine lanes, nothing else will ever prompt `RootInitialization`'s
                // resume-once-clear machinery to re-check, so this stop needs an explicit nudge
                // just as a non-success outcome does. (The engine-lane branch that skipped the
                // nudge here went with the scheduled-run delivery arm; this lane always nudges.)
                await migrationManager.refreshMigrationSyncGate()
            } catch {
                if let route = await migrationManager.routeBroadcastFailure(account.id, error: error) {
                    await send(.broadcastFailureRouted(route))
                }
                // R8-T4 (#3) composed with R7-T3's classification above: the route drives the
                // failure UI; the nudge independently resumes sync stopped for a broadcast that
                // never landed (the SDK gate never transitioned).
                if didStopSyncForBroadcast {
                    await migrationManager.refreshMigrationSyncGate()
                }
                await send(.transferResult(nil))
            }
        }
    }

    // (The R8-T6 send-now gate-check / silence-window machinery — `resolveSendGate`,
    // `waitEffect`, `setSendWaitActive` and the `migrationSendWaitActive` fence — was REMOVED
    // 2026-08-07 with the whole manual-tap send surface.)
}
