//
//  MigrationStatusStore.swift
//  zodl
//
//  Post-commit status screen. Two presentations:
//  - scheduledSuccess: the celebratory "Migration Scheduled" screen shown right after committing.
//  - progress: ongoing "N of M" progress, sync-step, and complete / complete-with-dust states.
//
//  Observes the SDK state stream so background-task progress shows live.
//

import ComposableArchitecture
import SwiftUI
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationStatus {
    @ObservableState
    struct State: Equatable {
        enum Presentation: Equatable {
            case scheduledSuccess
            case progress
        }

        var presentation: Presentation = .progress
        var migrationState: MigrationState = .notStarted
        var progress: MigrationProgress?
        var orchardRemaining: Zatoshi = .zero
        var summary: MigrationSummary = .zero
        /// Per-transfer rows for the in-progress list (Figma B8).
        var transfers: [MigrationTransferRow] = []

        var isComplete: Bool { migrationState == .complete }

        /// A scheduled transfer failed / missed its window → render "Resume Migration" (Send now / Reschedule).
        var isStalled: Bool {
            if case .requiresAttention(.transferStalled) = migrationState { return true }
            return false
        }

        /// 1-based number of the stalled transfer (0 when not stalled).
        var stalledTransferNumber: Int {
            if case let .requiresAttention(.transferStalled(number)) = migrationState { return number }
            return 0
        }

        init(presentation: Presentation = .progress) {
            self.presentation = presentation
        }
    }

    enum Action {
        enum Delegate: Equatable {
            case done
            case sendNow
            case reschedule
        }

        case onAppear
        case stateChanged(MigrationState)
        case doneTapped
        case sendNowTapped
        case rescheduleTapped
        case delegate(Delegate)
    }

    enum CancelID { case stateStream }

    @Dependency(\.migrationSDK) var migrationSDK

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.migrationState = migrationSDK.getMigrationState()
                state.progress = migrationSDK.getMigrationProgress()
                state.orchardRemaining = migrationSDK.simulatedOrchardBalance()
                state.summary = migrationSDK.migrationSummary()
                state.transfers = migrationSDK.migrationTransfers()
                return .publisher {
                    migrationSDK.stateStream().map(Action.stateChanged)
                }
                .cancellable(id: CancelID.stateStream, cancelInFlight: true)

            case let .stateChanged(migrationState):
                state.migrationState = migrationState
                state.progress = migrationSDK.getMigrationProgress()
                state.orchardRemaining = migrationSDK.simulatedOrchardBalance()
                state.summary = migrationSDK.migrationSummary()
                state.transfers = migrationSDK.migrationTransfers()
                return .none

            case .doneTapped:
                return .merge(
                    .cancel(id: CancelID.stateStream),
                    .send(.delegate(.done))
                )

            case .sendNowTapped:
                // Stay on screen — the coordinator broadcasts and the state stream refreshes us.
                return .send(.delegate(.sendNow))

            case .rescheduleTapped:
                return .send(.delegate(.reschedule))

            case .delegate:
                return .none
            }
        }
    }
}
