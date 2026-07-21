//
//  MigrationSendingStore.swift
//  zodl
//
//  "Sending" / "Sent" screen (MOB-1463, Figma S8 · sending 2618:6858 / sent 2618:6895). Shown while
//  a migration transfer broadcasts — for immediate/manual/plan-first sends, the dust lane, or the
//  S10 "Send now" lane — then flips to a success state once that one transfer has been executed.
//  `onAppear` runs `executeNextPendingMigrationTransfer`, recording a broadcast and scheduling the
//  next background window on success; a failure/`nil` result presents the failure sheet, and
//  `retryTapped` re-runs the same step (MOB-1466).
//
//  MOB-1496 (W5, ZIP-0318 MUST): a background session — and this screen's own executor — may
//  broadcast at most ONE overdue transfer. `totalCount`/`sentCount` remain (the "Send now" push site
//  still configures `totalCount` off the overdue row count, informational only now), but
//  `.transferResult`'s success handler no longer loops back into `executeNextTransfer` — a single
//  success always finishes the screen. Remaining overdue transfers stay scheduled; the next
//  background window (armed by `scheduleNextWindow()` below, per-account fanned-out — MOB-1496 W5
//  §2) picks them up, or the user taps "Send now" again (a separate, explicit decision each time —
//  the CTA is deliberately never disabled after a send). The `closeTapped` / `viewTransactionTapped`
//  delegates are consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  This same screen is reused for the "Migrate anyway" dust lane (MOB-1487): `isDustLane` routes
//  execution through the dedicated dust sweep instead of the next scheduled transfer. MOB-1494
//  (round 4) unified the on-screen copy on the "migrated" wording for every lane (the canvas
//  dropped the "sent" variant), so the flag no longer affects any strings — execution only.
//
//  R8-T6 (V8 fix — silence-window wait): `entersViaSendNow` marks the OTHER lane this screen
//  serves — the Status screen's "Send now" CTA (MigrationCoordFlowCoordinator's `.status
//  (.delegate(.sendNow))` push site). That lane no longer stops sync and broadcasts immediately:
//  `onAppear` stops sync FIRST, then reads the app-side `sendGate()` privacy gate — `.allowed`
//  broadcasts exactly like every other lane, but `.waitUntil`/`.syncRequired` enters a WAITING
//  phase (countdown to the gate's clear date, `@Dependency(\.continuousClock)`-driven) instead of
//  broadcasting into a gate that's still closed. Cancel during WAITING nudges Root's gate feed to
//  resume sync and closes without sending anything. The dust/immediate/manual/plan-first/Keystone
//  lanes are UNCHANGED — they never consulted `sendGate()` and still don't (`entersViaSendNow`
//  defaults `false`, so `onAppear` takes the same immediate stop+broadcast path as before for them).
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
            /// R8-T6 (send-now lane only): the app-side privacy gate isn't clear yet — counting down
            /// to `target` (the gate's `waitUntil` date, or a buffer-duration fallback when the gate
            /// read back a residual `.syncRequired`), sync held stopped, nothing broadcast yet.
            case waiting(target: Date)
            case success
        }

        var phase = Phase.sending
        /// Failure sheet presented over the sending phase.
        var isFailurePresented = false
        /// The most recently broadcast transfer's tx id (wires up View Transaction).
        var txId = ""
        /// MOB-1496 (W5, ZIP-0318): informational only — `onAppear` always executes AT MOST ONE
        /// transfer regardless of this value (the "send now" push site still configures it off the
        /// overdue row count, but `.transferResult`'s success handler no longer loops against it).
        /// Coordinator-configured.
        var totalCount = 1
        /// 0 before a send, 1 after — this screen never executes more than one transfer (MOB-1496 W5).
        var sentCount = 0
        /// When true, this instance is the "Migrate anyway" dust lane (MOB-1487): `onAppear`
        /// executes the dedicated dust sweep instead of the next scheduled transfer.
        /// Coordinator-configured; defaults to false so existing lanes are unaffected. Execution
        /// only — the on-screen copy is identical in every lane (MOB-1494).
        var isDustLane = false
        /// R8-T6: when true, this instance is the Status screen's "Send now" lane — `onAppear`
        /// stops sync then consults `sendGate()` first, entering `.waiting` instead of broadcasting
        /// immediately when the gate isn't clear. Coordinator-configured (`MigrationCoordFlowCoordinator`'s
        /// `.status(.delegate(.sendNow))` push site); defaults to false so every other lane keeps
        /// today's immediate stop+broadcast behavior unchanged.
        var entersViaSendNow = false
        /// Scopes the send-now gate-check/wait effects (`.cancellable`) — fixed for this instance's
        /// lifetime, same idiom as `MigrationStatus.State.cancelStateStreamId`.
        var cancelSendNowWaitId = UUID()
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        init(
            phase: Phase = .sending,
            isFailurePresented: Bool = false,
            txId: String = "",
            totalCount: Int = 1,
            sentCount: Int = 0,
            isDustLane: Bool = false,
            entersViaSendNow: Bool = false
        ) {
            self.phase = phase
            self.isFailurePresented = isFailurePresented
            self.txId = txId
            self.totalCount = totalCount
            self.sentCount = sentCount
            self.isDustLane = isDustLane
            self.entersViaSendNow = entersViaSendNow
        }
    }

    enum Action: BindableAction, Equatable {
        /// The screen's one transfer has been successfully broadcast (MOB-1496 W5: never more than
        /// one, regardless of `totalCount`).
        case allTransfersSent
        case binding(BindingAction<State>)
        /// Failure sheet: dismiss (stay on screen).
        case cancelTapped
        case closeTapped
        case delegate(Delegate)
        case onAppear
        /// Failure sheet: dismiss, then re-run the failed step.
        case retryTapped
        /// R8-T6 (send-now lane only): `stopSyncBeforeMigrationBroadcast()` + `sendGate()` result
        /// (the single settle retry on a raced `.syncRequired` folded in) — `.allowed` broadcasts,
        /// `.waitUntil`/residual `.syncRequired` (re-)enters `.waiting` against the given/fallback
        /// target. Also the fire-time re-check's own result (`.waitFired` resolves through here too).
        case sendNowGateResolved(MigrationSendGate)
        /// `executeNextPendingMigrationTransfer` result for the current step; `nil` on a stub/no-op.
        case transferResult(MigrationTransferResult?)
        case viewTransactionTapped
        /// R8-T6: WAITING phase's Cancel affordance (also swipe-dismiss, on any surface that allows
        /// it — see this task's report). Nothing broadcasts; nudges Root's app-side gate feed to
        /// resume sync, then closes exactly like the success screen's Close.
        case waitCancelTapped
        /// R8-T6: the WAITING phase's clock-driven countdown reached its target — time to re-check
        /// the gate (`sendNowGateResolved` handles both the broadcast-now and still-blocked outcomes).
        case waitFired

        enum Delegate: Equatable {
            case closed
            case viewTransaction
        }
    }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.migrationBGScheduler) var migrationBGScheduler
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

            case .binding:
                return .none

            case .cancelTapped:
                state.isFailurePresented = false
                return .none

            case .closeTapped:
                return .send(.delegate(.closed))

            case .delegate:
                return .none

            case .onAppear:
                // R8-T6: the send-now lane routes through the gate-check/wait flow FIRST; every
                // other lane (dust, immediate/manual/plan-first review, Keystone) keeps today's
                // immediate stop+broadcast — they never consulted `sendGate()` and still don't.
                if state.entersViaSendNow {
                    return resolveSendGateEffect(waitId: state.cancelSendNowWaitId)
                }
                return executeNextTransfer(account: state.selectedWalletAccount, isDustLane: state.isDustLane)

            case .retryTapped:
                state.isFailurePresented = false
                return executeNextTransfer(account: state.selectedWalletAccount, isDustLane: state.isDustLane)

            case .sendNowGateResolved(let gate):
                // A `.waitUntil`/`.syncRequired` arriving while `state.phase` is ALREADY `.waiting`
                // means this is `.waitFired`'s fire-time re-check finding the gate still blocked
                // (e.g. a stop raced) rather than the initial tap's first read — logged, since it's
                // an unexpected-but-handled re-entry, not the normal path.
                let isFireTimeReEntry: Bool
                if case .waiting = state.phase {
                    isFireTimeReEntry = true
                } else {
                    isFireTimeReEntry = false
                }

                switch gate {
                case .allowed:
                    state.phase = .sending
                    setSendWaitActive(false)
                    return executeNextTransfer(account: state.selectedWalletAccount, isDustLane: false)

                case .waitUntil(let target):
                    if isFireTimeReEntry {
                        LoggerProxy.warn("Migration send-now: gate still blocked at wait-fire time, re-entering wait")
                    }
                    state.phase = .waiting(target: target)
                    setSendWaitActive(true)
                    return waitEffect(target: target, waitId: state.cancelSendNowWaitId)

                case .syncRequired:
                    // Still blocked even after `resolveSendGate`'s own settle retry — never
                    // broadcast into it. No date to wait against, so fall back to the full privacy
                    // buffer from now, same as a fresh sync completion would produce.
                    if isFireTimeReEntry {
                        LoggerProxy.warn("Migration send-now: gate still blocked at wait-fire time, re-entering wait")
                    }
                    let fallbackTarget = Date().addingTimeInterval(sdkSynchronizer.migrationPrivacySyncBufferDuration())
                    state.phase = .waiting(target: fallbackTarget)
                    setSendWaitActive(true)
                    return waitEffect(target: fallbackTarget, waitId: state.cancelSendNowWaitId)
                }

            case .waitCancelTapped:
                // Nothing broadcasts. Clear the hold BEFORE the nudge so `RootInitialization`'s
                // `.retryStart` (replayed by the nudge's eventual `.migrationSyncGateChanged`) sees
                // it already cleared and actually resumes sync instead of re-deferring.
                setSendWaitActive(false)
                return .concatenate(
                    .cancel(id: state.cancelSendNowWaitId),
                    .run { [migrationManager] _ in await migrationManager.refreshMigrationSyncGate() },
                    .send(.delegate(.closed))
                )

            case .waitFired:
                return resolveSendGateEffect(waitId: state.cancelSendNowWaitId)

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
                    // scheduleNextWindow() is async (MOB-1467) — concatenated ahead of the
                    // follow-up effect so it still runs to completion first, matching the previous
                    // synchronous call-then-continue ordering. MOB-1496: `reconcile()` also runs
                    // here so `migrationManager.stateEvents` picks up the just-completed transfer
                    // promptly (a store completing a migration op is one of `reconcile()`'s two
                    // triggers). MOB-1496 (W2): `recordTransferBroadcast` persists the sent record
                    // the SDK itself no longer retains — runs before `reconcile()` so the freshly
                    // reconciled state is observed alongside an already-updated schedule.
                    return .concatenate(
                        .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] _ in
                            await migrationManager.recordTransferBroadcast(accountUUID, MigrationTransferResult.success(txId: txId))
                        },
                        .run { [migrationBGScheduler] _ in await migrationBGScheduler.scheduleNextWindow() },
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

    /// The dust lane ("Migrate anyway", MOB-1487) executes the dedicated dust sweep — never
    /// `executeNextPendingMigrationTransfer`, which is the scheduled-transfer path a background
    /// poll also drives and which must not move unconsented dust.
    ///
    /// MOB-1496: `migrateMigrationDust` needs the account's USK to sign — Keystone accounts have no
    /// PCZT-based dust-sweep lane yet (the SDK's composite has no PCZT variant), so they short-
    /// circuit to `nil` (surfaces as the ordinary failure sheet) rather than attempting a USK
    /// derivation that would misbehave for a hardware-wallet account. `executeNextPendingMigrationTransfer`
    /// needs no signing (it broadcasts an already-signed pending transfer), so it stays account-only
    /// for both vendors. `ZcashError.migrationRecordFailedAfterBroadcast` means the broadcast DID
    /// land and only recording failed (the engine self-heals later) — routed to a success-like
    /// result so the UX doesn't offer a needless retry or imply failure for something that worked;
    /// `txId` is a placeholder (the error carries no payload to recover the real one from).
    private func executeNextTransfer(account: WalletAccount?, isDustLane: Bool) -> Effect<Action> {
        guard let account else {
            return .run { send in await send(.transferResult(nil)) }
        }

        return .run { send in
            // MOB-1496 (R8-T4, #3): tracks whether `stopSyncBeforeMigrationBroadcast()` actually ran
            // THIS attempt — only a stop that was never followed by a successful broadcast needs the
            // nudge (see `migrationManager.refreshMigrationSyncGate`'s doc); the guards above (no
            // account / Keystone dust lane) return before ever stopping sync, so they must not nudge.
            var didStopSyncForBroadcast = false
            do {
                let result: MigrationTransferResult?
                if isDustLane {
                    guard account.vendor != WalletAccount.Vendor.keystone, let zip32AccountIndex = account.zip32AccountIndex else {
                        await send(.transferResult(nil))
                        return
                    }
                    let usk = try MigrationSpendingKeyDerivation.deriveUSK(
                        zip32AccountIndex: zip32AccountIndex,
                        walletStorage: walletStorage,
                        mnemonic: mnemonic,
                        derivationTool: derivationTool,
                        networkType: zcashSDKEnvironment.network().networkType
                    )
                    // MOB-1496 (W4): read AT EXECUTE TIME, right before the broadcast — never trust a
                    // value threaded through state, which would go stale across a re-entry (coordinator
                    // state resets on relaunch) or a long BG-window gap.
                    let options = await migrationManager.migrationNetworkOptions(account.id)
                    await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
                    didStopSyncForBroadcast = true
                    result = try await sdkSynchronizer.migrateMigrationDust(account.id, usk, options)
                } else {
                    let options = await migrationManager.migrationNetworkOptions(account.id)
                    await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
                    didStopSyncForBroadcast = true
                    result = try await sdkSynchronizer.executeNextPendingMigrationTransfer(account.id, options)
                }
                await send(.transferResult(result))
                // A `.success` result is the ONLY outcome the SDK's own gate transitions on — every
                // other outcome (`.networkError`/`.invalidNote`/`.expired`/`nil`) stopped sync above
                // without ever reaching that transition, so nudge Root's gate feed directly.
                if case MigrationTransferResult.success? = result {
                    // no nudge — the SDK's gate transition covers the resume.
                } else if didStopSyncForBroadcast {
                    await migrationManager.refreshMigrationSyncGate()
                }
            } catch ZcashError.migrationRecordFailedAfterBroadcast(_) {
                // The broadcast DID land; only recording failed — treated as landed (like `.success`),
                // so no nudge either.
                await send(.transferResult(MigrationTransferResult.success(txId: "")))
            } catch {
                if didStopSyncForBroadcast {
                    await migrationManager.refreshMigrationSyncGate()
                }
                await send(.transferResult(nil))
            }
        }
    }

    // MARK: - R8-T6: send-now lane gate-check / silence-window wait

    private enum Constants {
        /// `.syncRequired` immediately after our own stop is a settle race, not a genuine block —
        /// one short, bounded wait before the single re-read `resolveSendGate()` allows.
        static let gateSettleDelay: Duration = .milliseconds(300)
    }

    /// `stopSyncBeforeMigrationBroadcast()` FIRST, then read `sendGate()` — order matters (reading
    /// the gate before stopping could read a stale `.allowed` a moment before our own stop, or race
    /// a DIFFERENT lane's concurrent sync completion). `.syncRequired` immediately after our own
    /// stop means the stop hasn't necessarily drained `isSyncing()` yet (an async SDK teardown
    /// race, not a genuine block) — settled with a single bounded retry (re-stop, defensively, then
    /// re-read); whatever comes back — even a residual `.syncRequired` — is `.sendNowGateResolved`'s
    /// to interpret (it falls back to a full buffer-duration wait), so this never spins.
    private func resolveSendGate() async -> MigrationSendGate {
        await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
        let gate = await migrationManager.sendGate()
        guard gate == MigrationSendGate.syncRequired else { return gate }

        try? await clock.sleep(for: Constants.gateSettleDelay)
        await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
        return await migrationManager.sendGate()
    }

    private func resolveSendGateEffect(waitId: UUID) -> Effect<Action> {
        .run { send in
            let gate = await resolveSendGate()
            await send(.sendNowGateResolved(gate))
        }
        .cancellable(id: waitId, cancelInFlight: true)
    }

    /// Target-date + clock sleep — NOT a decrementing int — so a suspend/resume (e.g. a brief
    /// backgrounding) can never desync the fire time from the wall-clock target `.waiting` displays.
    /// The sleep only decides WHEN to re-check; `.waitFired`'s fresh `resolveSendGate()` read is the
    /// actual authority on whether it's really clear, so minor timing slack here is harmless.
    private func waitEffect(target: Date, waitId: UUID) -> Effect<Action> {
        .run { send in
            let remaining = target.timeIntervalSinceNow
            if remaining > 0 {
                try? await clock.sleep(for: .seconds(remaining))
            }
            await send(.waitFired)
        }
        .cancellable(id: waitId, cancelInFlight: true)
    }

    /// R8-T6 (MANDATORY TRACE fence): same `@Shared(.inMemory(...))` idiom as `SDKSynchronizerClient
    /// .stopSyncBeforeMigrationBroadcast()`'s own `migrationStoppedSyncForBroadcast` flag. Set while
    /// `.waiting`, cleared on broadcast-start/cancel/close — `RootInitialization`'s `.retryStart`
    /// proactive section defers (without alerting) while this is set, so no foreground trigger that
    /// routes through it (scene-phase re-entry, the SDK gate's own resume replay, a DIFFERENT lane's
    /// failure nudge — see this task's report for the traced list) can restart sync mid-wait.
    private func setSendWaitActive(_ isActive: Bool) {
        @Shared(.inMemory(.migrationSendWaitActive)) var migrationSendWaitActive: Bool = false
        $migrationSendWaitActive.withLock { $0 = isActive }
    }
}
