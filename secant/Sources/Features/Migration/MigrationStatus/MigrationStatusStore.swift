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
