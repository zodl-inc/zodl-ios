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

        init(presentation: Presentation = .progress) {
            self.presentation = presentation
        }
    }

    enum Action {
        enum Delegate: Equatable {
            case done
        }

        case onAppear
        case stateChanged(MigrationState)
        case doneTapped
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
                return .publisher {
                    migrationSDK.stateStream().map(Action.stateChanged)
                }
                .cancellable(id: CancelID.stateStream, cancelInFlight: true)

            case let .stateChanged(migrationState):
                state.migrationState = migrationState
                state.progress = migrationSDK.getMigrationProgress()
                state.orchardRemaining = migrationSDK.simulatedOrchardBalance()
                return .none

            case .doneTapped:
                return .merge(
                    .cancel(id: CancelID.stateStream),
                    .send(.delegate(.done))
                )

            case .delegate:
                return .none
            }
        }
    }
}
