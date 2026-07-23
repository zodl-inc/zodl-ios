//
//  MigrationBGSchedulerLiveKey.swift
//  Zashi
//
//  Live implementation of `MigrationBGSchedulerClient`. The branch decision (submit a BG task vs.
//  schedule a manual-mode "ready" notification vs. cancel everything because the migration is
//  done) is factored into the pure, table-testable `WakeupAction.decide` (mirroring
//  `MigrationDerivations` in MigrationManagerLiveKey.swift) so `MigrationBGSchedulerTests` can
//  exercise every row without touching `BGTaskScheduler` or `UNUserNotificationCenter`; this file
//  only computes the inputs and executes the resulting action.
//

@preconcurrency import BackgroundTasks
import UIKit
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension MigrationBGSchedulerClient: DependencyKey {
    static let liveValue: MigrationBGSchedulerClient = Self.live()

    static func live() -> Self {
        let impl = MigrationBGSchedulerImpl()

        return MigrationBGSchedulerClient(
            backgroundRefreshStatus: {
                await MainActor.run {
                    UIApplication.shared.backgroundRefreshStatus
                }
            },
            scheduleFirstWindow: { await impl.arm(margin: MigrationCadence.firstWindowMargin) },
            scheduleNextWindow: { await impl.arm(margin: MigrationCadence.nextWindowMargin) },
            cancelAll: { await impl.cancelAll() }
        )
    }
}

/// Composes `migrationManager` + `sdkSynchronizer` + `userNotifications` and turns their current
/// readings into a `WakeupAction`, then executes it. `@unchecked Sendable`: holds no mutable state
/// of its own — every dependency it wraps is itself `Sendable`. Not `private` (MOB-1496 W5): unit
/// tests instantiate this directly with injected dependencies, the same testability pattern
/// `MigrationManagerImpl` already uses.
final class MigrationBGSchedulerImpl: @unchecked Sendable {
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.userNotifications) var userNotifications
    @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
    /// MOB-1496 (W5): the rest of the wallet's accounts — `arm(margin:)` fans out over
    /// `MigrationDerivations.candidateAccountUUIDs(selectedAccountUUID:walletAccounts:)` (selected
    /// first, then this list's stored order), the same source `MigrationManagerImpl
    /// .activeNetworkSnapshots()` already reads.
    @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []

    /// Shared by `scheduleFirstWindow`/`scheduleNextWindow` — only the margin differs. The
    /// complete-check choke point lives inside `WakeupAction.decide`, so both call sites uniformly
    /// no-op (cancel) once every account is done, without duplicating that check here.
    ///
    /// MOB-1496 (W5): fans out over EVERY candidate account (selected first, then stored order) — a
    /// throwing `getMigrationState`/`getMigrationProgress` for one account degrades to a
    /// conservative-active marker for THAT account only (R8-T5 #8 — see the catch branch below and
    /// `MigrationCadence.RearmPlan`'s doc), never aborting the whole arm; `rescheduleOverdueMigrationTransfer`
    /// stays its own `try?`-guarded probe (a thrown read and a genuinely-empty probe both read as "no
    /// proposal"). No accounts skips arming entirely — nothing to arm for.
    ///
    /// R8-T5 (#8): EVERY account's reads failing no longer skips arming either. Before this fix, a
    /// dropped-on-catch account left `rearmInputs` empty in that case and this function returned
    /// having armed NOTHING — silently killing the wakeup chain on a transient failure, since no
    /// other call site re-attempts `arm(margin:)` on its own (`willEnterForeground` only calls
    /// `migrationManager.reconcile()`, which does not re-arm — the doc here used to claim otherwise).
    /// Now every account contributes an entry (real data or the conservative-active marker), so
    /// `planRearm` resolves a non-`.complete` representative state and this arms a retry window at
    /// `margin` instead. The per-account data is reduced to a single earliest-across-accounts window
    /// via the pure `MigrationCadence.planRearm(_:)` before `window(margin:preferredExecutableAt:
    /// now:)`/`WakeupAction.decide` run (S4: `WakeupAction.decide` now also threads the winning
    /// account through — see its own doc).
    func arm(margin: TimeInterval) async {
        let accountUUIDs = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: selectedWalletAccount?.id,
            walletAccounts: walletAccounts
        )
        guard !accountUUIDs.isEmpty else {
            LoggerProxy.event("MigrationBGScheduler.arm: no accounts, skipping.")
            return
        }

        var rearmInputs: [MigrationCadence.AccountRearmInput] = []
        for accountUUID in accountUUIDs {
            do {
                let state = try await sdkSynchronizer.getMigrationState(accountUUID)
                let progress = try await sdkSynchronizer.getMigrationProgress(accountUUID)
                // Double-optional flatten: `rescheduleOverdueMigrationTransfer` already returns an
                // Optional on success, and `try?` adds a second layer — a thrown read and a
                // genuinely-empty probe both read as "no proposal" here (mirrors
                // `MigrationManagerImpl.migrationSummary`'s identical `residual` flatten).
                let proposal = (try? await sdkSynchronizer.rescheduleOverdueMigrationTransfer(accountUUID)) ?? nil
                rearmInputs.append(
                    MigrationCadence.AccountRearmInput(
                        accountUUID: accountUUID,
                        state: state,
                        progress: progress,
                        nextExecutableAfterHeight: proposal?.nextExecutableAfterHeight
                    )
                )
            } catch {
                // R8-T5 (#8): keep the account in `rearmInputs` as conservative-active rather than
                // dropping it — a dropped account could never block `planRearm`'s `representativeState`
                // from resolving `.complete`, so a transient read failure on an account with a
                // genuinely active run could wrongly satisfy "every account done" and trigger
                // `WakeupAction.cancelAll` (see `MigrationCadence.RearmPlan`'s doc). `state`/
                // `progress`/`nextExecutableAfterHeight` are unused placeholders here —
                // `isUnreadable: true` means `planRearm` never consults them.
                LoggerProxy.error("MigrationBGScheduler.arm: SDK read failed for an account \(error)")
                rearmInputs.append(
                    MigrationCadence.AccountRearmInput(
                        accountUUID: accountUUID,
                        state: MigrationState.splitPendingConfirmation,
                        progress: nil,
                        nextExecutableAfterHeight: nil,
                        isUnreadable: true
                    )
                )
            }
        }

        // R8-T5 (#8): `rearmInputs` now always has exactly one entry per `accountUUIDs` element
        // (success or the conservative-active marker above), so it can never end up empty here —
        // the `!accountUUIDs.isEmpty` guard above is the only emptiness check this function needs.
        let plan = MigrationCadence.planRearm(rearmInputs)
        let preferredExecutableAt = plan.earliestNextExecutableAfterHeight.flatMap { height in
            sdkSynchronizer.estimateTimestamp(height).map { Date(timeIntervalSince1970: $0) }
        }
        let window = MigrationCadence.window(
            margin: margin,
            preferredExecutableAt: preferredExecutableAt,
            now: Date()
        )

        // R8-T5 (S4): the winning account, hex-encoded (`Data.hexEncodedString()` — the same
        // encoding `MigrationManagerLiveKey`'s own per-account storage key already uses) — carried
        // into the manual-delivery "ready to send" notification's payload so a tap can open the
        // RIGHT account instead of always resolving `selectedWalletAccount` at the destination.
        let winnerAccountUUIDString = plan.winnerAccountUUID.map { Data($0.id).hexEncodedString() }

        let action = WakeupAction.decide(
            state: plan.representativeState,
            // MOB-1509: the manual-delivery flag follows the WINNING account (whose transfer this
            // wakeup serves); nil (no winner, e.g. a sync-only wakeup) resolves the selected one.
            isManualDelivery: migrationManager.isManualDelivery(plan.winnerAccountUUID),
            window: window,
            nextTransferNumber: plan.nextTransferNumber,
            accountUUID: winnerAccountUUIDString
        )

        await execute(action)
    }

    func cancelAll() async {
        await execute(WakeupAction.cancelAll)
    }

    private func execute(_ action: WakeupAction) async {
        switch action {
        case let .submitTask(earliestBeginDate):
            let request = BGProcessingTaskRequest(identifier: MigrationBGTask.identifier)
            request.earliestBeginDate = earliestBeginDate
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false
            try? BGTaskScheduler.shared.submit(request)

        case let .scheduleReadyNotification(number, at, accountUUID):
            await userNotifications.scheduleMigrationNotification(.manualTransferReady(number: number), at, accountUUID)

        case .cancelAll:
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: MigrationBGTask.identifier)
            await userNotifications.cancelMigrationNotifications()
        }
    }
}

// MARK: - Pure decision (table-testable, no SDK/framework dependency)

/// What to do when arming the next migration wakeup. Scheduled mode submits a `BGProcessingTask`
/// request; manual mode pre-schedules the "ready to send" notification (§4.4 approved decision 3
/// — manual mode has no BG sessions, so its reminder is time-scheduled up front rather than
/// posted live from a session). Either branch is skipped in favor of `.cancelAll` once the
/// migration is `.complete` — the choke point that prevents an infinite +6.5 h no-op chain.
enum WakeupAction: Equatable {
    case submitTask(earliestBeginDate: Date)
    case scheduleReadyNotification(number: Int, at: Date, accountUUID: String?)
    case cancelAll

    /// `state` gates everything: `.complete` always wins, regardless of `isManualDelivery`.
    /// Otherwise: manual -> `.scheduleReadyNotification`, scheduled -> `.submitTask`.
    ///
    /// R8-T5 (S4): `accountUUID` (`arm(margin:)`'s hex-encoded `RearmPlan.winnerAccountUUID`) rides
    /// along into `.scheduleReadyNotification` only — the scheduled-mode `.submitTask` branch has no
    /// notification of its own to attribute here (the BG session tree composes its own, per-account,
    /// when the task actually runs).
    static func decide(
        state: MigrationState,
        isManualDelivery: Bool,
        window: Date,
        nextTransferNumber: Int,
        accountUUID: String?
    ) -> WakeupAction {
        guard state != MigrationState.complete else {
            return WakeupAction.cancelAll
        }

        if isManualDelivery {
            return WakeupAction.scheduleReadyNotification(number: nextTransferNumber, at: window, accountUUID: accountUUID)
        }

        return WakeupAction.submitTask(earliestBeginDate: window)
    }
}
