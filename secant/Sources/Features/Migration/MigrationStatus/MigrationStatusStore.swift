//
//  MigrationStatusStore.swift
//  zodl
//
//  "Migration Progress" / "Resume Migration" / "Re-scheduling…" screen (MOB-1464, Figma S10 ·
//  progress 2709:3350 / resume 2696:7133 / re-scheduling 2840:3656). `onAppear` loads rows/summary
//  via `migrationTransfers()`/`migrationSummary()`, derives `isSendNowDisabled` from
//  `manager.sendGate()`, and subscribes `migrationStateStream()` to refresh rows live (MOB-1466).
//  When this screen is a flow re-entry root (`isFlowRoot`), its back control closes the flow
//  (`.done`) instead of popping — every other delegate is consumed by
//  `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  MOB-1478 (W7): rows can now carry sub-hour sent recency (`sentMinutesAgo`) and a broadcasting
//  flag (`isBroadcasting`) — both just ride along through `statusLoaded`/`migrationStateChanged`
//  unchanged; the View derives their captions. `.rescheduleConfirmed(first:last:)` is a new
//  presentation reached via the public `rescheduleCompleted` action, landing on this same screen
//  instead of flipping `isRescheduling` back to `.resume`. The reschedule effect itself (SDK
//  reschedule + background-window scheduling) still runs in `MigrationCoordFlowCoordinator`, which
//  today pushes a fresh `TransferPlan` screen on completion instead — wiring it to send
//  `rescheduleCompleted` here is a later phase.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationStatus {
    @ObservableState
    struct State: Equatable {
        enum Presentation: Equatable {
            case progress
            case resume
            /// Post-reschedule confirmation (MOB-1478 W7): entered via `rescheduleCompleted` instead
            /// of flipping back to `.resume`. `first`/`last` are the stalled-range transfer numbers
            /// ("Transfers {first}-{last}") captured from `.resume`'s `stalledNumber`/`rows.count` at
            /// the moment of transition.
            case rescheduleConfirmed(first: Int, last: Int)
        }

        var presentation = Presentation.progress
        var rows: IdentifiedArrayOf<MigrationTransferRow> = []
        var totalDurationHours = 0
        /// Resume header: "Transfer {n} of {m} …".
        var stalledNumber = 0
        var stalledHoursAgo = 0
        /// Visual-only: skeleton captions + disabled spinner button on the resume presentation.
        var isRescheduling = false
        /// True when this screen is the coordinator's re-entry root (both presentations) — its back
        /// control then closes the flow instead of popping.
        var isFlowRoot = false
        /// Send-now CTA disabled per `manager.sendGate()` (`.syncRequired`/`.waitUntil` -> disabled).
        var isSendNowDisabled = false
        var cancelStateStreamId = UUID()

        var remainingCount: Int {
            rows.filter { $0.status != .sent }.count
        }

        init(
            presentation: Presentation = .progress,
            rows: IdentifiedArrayOf<MigrationTransferRow> = [],
            totalDurationHours: Int = 0,
            stalledNumber: Int = 0,
            stalledHoursAgo: Int = 0,
            isRescheduling: Bool = false,
            isFlowRoot: Bool = false
        ) {
            self.presentation = presentation
            self.rows = rows
            self.totalDurationHours = totalDurationHours
            self.stalledNumber = stalledNumber
            self.stalledHoursAgo = stalledHoursAgo
            self.isRescheduling = isRescheduling
            self.isFlowRoot = isFlowRoot
        }
    }

    enum Action: Equatable {
        /// Flow-root back control: closes the flow instead of popping.
        case closeTapped
        /// Progress CTA and the X close.
        case gotItTapped
        case delegate(Delegate)
        /// `migrationStateStream()` ticked — reloads rows/summary/gate.
        case migrationStateChanged
        case onAppear
        /// Public: the coordinator's reschedule effect (SDK reschedule + first-window scheduling)
        /// finished — lands on `.rescheduleConfirmed` with the refreshed rows/duration instead of
        /// flipping `isRescheduling` back to `.resume`. The coordinator doesn't send this yet (it
        /// still pushes a fresh `TransferPlan` screen on completion) — wiring it up is a later phase;
        /// this action is the store-side surface for it (MOB-1478 W7).
        case rescheduleCompleted(rows: [MigrationTransferRow], totalDurationHours: Int)
        case rescheduleTapped
        case sendNowTapped
        /// `migrationTransfers()` + `migrationSummary()` + `manager.sendGate()` result.
        case statusLoaded(rows: [MigrationTransferRow], totalDurationHours: Int, isSendNowDisabled: Bool)

        enum Delegate: Equatable {
            case done
            case reschedule
            case sendNow
        }
    }

    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .closeTapped:
                return .send(.delegate(.done))

            case .gotItTapped:
                return .send(.delegate(.done))

            case .delegate:
                return .none

            case .migrationStateChanged:
                return loadStatus()

            case .onAppear:
                return .merge(
                    loadStatus(),
                    .publisher {
                        sdkSynchronizer.migrationStateStream()
                            .map { _ in Action.migrationStateChanged }
                    }
                    .cancellable(id: state.cancelStateStreamId, cancelInFlight: true)
                )

            case .rescheduleCompleted(let rows, let totalDurationHours):
                state.presentation = .rescheduleConfirmed(first: state.stalledNumber, last: state.rows.count)
                state.rows = IdentifiedArrayOf(uniqueElements: rows)
                state.totalDurationHours = totalDurationHours
                state.isRescheduling = false
                return .none

            case .rescheduleTapped:
                state.isRescheduling = true
                return .send(.delegate(.reschedule))

            case .sendNowTapped:
                return .send(.delegate(.sendNow))

            case .statusLoaded(let rows, let totalDurationHours, let isSendNowDisabled):
                state.rows = IdentifiedArrayOf(uniqueElements: rows)
                state.totalDurationHours = totalDurationHours
                state.isSendNowDisabled = isSendNowDisabled
                return .none
            }
        }
    }

    private func loadStatus() -> Effect<Action> {
        .run { send in
            let rows = sdkSynchronizer.migrationTransfers()
            let summary = sdkSynchronizer.migrationSummary()
            let isSendNowDisabled = migrationManager.sendGate() != MigrationSendGate.allowed
            await send(
                .statusLoaded(
                    rows: rows,
                    totalDurationHours: summary.estimatedDurationHours,
                    isSendNowDisabled: isSendNowDisabled
                )
            )
        }
    }
}
