//
//  MigrationCoordFlowStore.swift
//  Zashi
//
//  Coordinator for the Orchard -> Ironwood migration flow (MOB-1466). Chains the visual-only
//  migration screens (MOB-1460...1464) into a live, state-driven flow: re-entry routing, mode/
//  network-privacy persistence, permission-step sequencing, and the scheduled/manual/immediate
//  chaining table. `MigrationEntry` is the flow's root screen (mirroring `SendCoordFlow`'s
//  `sendFormState`); every other screen lives in `path`. Everything here runs against the inert
//  SDK stubs — it goes live when the real SDK (MOB-1455) fills them in.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationCoordFlow {
    @Reducer(state: .equatable)
    enum Path {
        case backgroundDelivery(MigrationBackgroundDelivery)
        case complete(MigrationComplete)
        case networkPrivacy(MigrationNetworkPrivacy)
        case noteSplit(MigrationNoteSplit)
        case notifications(MigrationNotifications)
        case recovery(MigrationRecovery)
        case reviewTransfer(MigrationReviewTransfer)
        case scheduled(MigrationScheduled)
        case sending(MigrationSending)
        case status(MigrationStatus)
        case transferPlan(MigrationTransferPlan)
    }

    @ObservableState
    struct State: Equatable {
        var path = StackState<Path.State>()
        var entryState = MigrationEntry.State()
        /// Persisted via `manager.setMigrationMode` once chosen; held here too so later hops in
        /// the same run (e.g. immediate's Tor-skip) don't need to re-read the dependency.
        var mode: MigrationMode?
        /// Held here once confirmed on the Network Privacy screen (or defaulted when S5 is
        /// skipped) so Sending's coordinator-configured state can inject it.
        var networkPrivacyOptions = NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil)

        init() { }
    }

    /// Result of the async permission-step helper (`nextPermissionStepPathState()`): the screen
    /// to push (`nil` once every permission step is satisfied and the flow can proceed straight to
    /// the plan/review screen the caller already knows to push), plus whether Network Privacy (S5)
    /// was skipped because the app-wide Tor setup flag is already on — in which case the
    /// coordinator force-sets `networkPrivacyOptions.useTor = true` before proceeding.
    struct PermissionStepResult: Equatable {
        var pathState: Path.State?
        var forcedUseTor = false
    }

    enum Action {
        case entry(MigrationEntry.Action)
        case flowFinished
        case onAppear
        case path(StackActionOf<Path>)
        /// Internal: the async re-entry/permission-step helper resolved the next screen to push
        /// (or `nil` when nothing needs appending — the `.entry` re-entry route).
        case pushNextPermissionStep(PermissionStepResult)
        /// Internal: a fresh `MigrationStatus.State` (already hydrated) to push — used by Sending's
        /// manual-first-transfer close (no `.status` beneath yet). A dedicated case (rather than
        /// reusing `pushHydratedPathState`) so its `isFlowRoot: false` (mid-flow push) stays
        /// visibly distinct in the reducer from the re-entry root's `isFlowRoot: true` status push.
        case pushHydratedStatus(MigrationStatus.State)
        /// Internal: a fresh `Path.State` (already hydrated) to push — used by Status `.sendNow`'s
        /// overdue-batch Sending screen, Status `.reschedule`'s rescheduled plan, and Recovery
        /// `.recreate`'s re-created plan.
        case pushHydratedPathState(Path.State)
        /// Internal: sendNow's Sending screen finished (`.closed`) — refresh the `.status` element
        /// beneath with freshly-read rows and pop back to it.
        case sendNowCompleted(rows: [MigrationTransferRow])
    }

    @Dependency(\.migrationBGScheduler) var migrationBGScheduler
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.userNotifications) var userNotifications
    @Dependency(\.walletStorage) var walletStorage

    init() { }

    var body: some Reducer<State, Action> {
        coordinatorReduce()

        Scope(state: \.entryState, action: \.entry) {
            MigrationEntry()
        }

        Reduce { _, _ in .none }
            .forEach(\.path, action: \.path)
    }
}
