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
    /// MOB-1496 (W5): fans out over EVERY candidate account (selected first, then stored order) —
    /// each account's `getMigrationState`/`getMigrationProgress`/`rescheduleOverdueMigrationTransfer`
    /// is `try?`-guarded independently (log-and-skip per the BG session tree's own pattern: a read
    /// failure degrades to skipping just that account, not aborting the whole arm). No accounts, or
    /// EVERY account's reads failing, skips arming entirely rather than crashing — a later call
    /// (foreground entry, the next transfer's own completion) re-attempts. The per-account data is
    /// reduced to a single earliest-across-accounts window via the pure `MigrationCadence
    /// .planRearm(_:)` before `window(margin:preferredExecutableAt:now:)`/`WakeupAction.decide` run,
    /// both unchanged.
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
                        state: state,
                        progress: progress,
                        nextExecutableAfterHeight: proposal?.nextExecutableAfterHeight
                    )
                )
            } catch {
                LoggerProxy.error("MigrationBGScheduler.arm: SDK read failed for an account \(error)")
            }
        }

        guard !rearmInputs.isEmpty else {
            LoggerProxy.error("MigrationBGScheduler.arm: every account's SDK read failed, skipping.")
            return
        }

        let plan = MigrationCadence.planRearm(rearmInputs)
        let preferredExecutableAt = plan.earliestNextExecutableAfterHeight.flatMap { height in
            sdkSynchronizer.estimateTimestamp(height).map { Date(timeIntervalSince1970: $0) }
        }
        let window = MigrationCadence.window(
            margin: margin,
            preferredExecutableAt: preferredExecutableAt,
            now: Date()
        )

        let action = WakeupAction.decide(
            state: plan.representativeState,
            isManualDelivery: migrationManager.isManualDelivery(),
            window: window,
            nextTransferNumber: plan.nextTransferNumber
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

        case let .scheduleReadyNotification(number, at):
            await userNotifications.scheduleMigrationNotification(.manualTransferReady(number: number), at)

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
    case scheduleReadyNotification(number: Int, at: Date)
    case cancelAll

    /// `state` gates everything: `.complete` always wins, regardless of `isManualDelivery`.
    /// Otherwise: manual -> `.scheduleReadyNotification`, scheduled -> `.submitTask`.
    static func decide(
        state: MigrationState,
        isManualDelivery: Bool,
        window: Date,
        nextTransferNumber: Int
    ) -> WakeupAction {
        guard state != MigrationState.complete else {
            return WakeupAction.cancelAll
        }

        if isManualDelivery {
            return WakeupAction.scheduleReadyNotification(number: nextTransferNumber, at: window)
        }

        return WakeupAction.submitTask(earliestBeginDate: window)
    }
}
