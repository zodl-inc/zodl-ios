//
//  OrchardMigrationStore.swift
//  ZODL
//

import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

@Reducer
struct OrchardMigration {

    // MARK: - State

    @ObservableState
    struct State: Equatable {
        var phase: MigrationProcessorClient.Phase = .unknown
        /// Tor is ON by default per migration design doc §9.3. User can opt out via toggle.
        var torEnabled: Bool = true
        var cancelId = UUID()
    }

    // MARK: - Action

    enum Action: Equatable {
        case onAppear
        case onDisappear
        case processorStateChanged(MigrationProcessorClient.Phase)
        case torToggled(Bool)

        // User confirmation actions driven from the view
        case noteSplitConfirmTapped(MigrationProcessorClient.NoteSplitProposalModel)
        case scheduleConfirmTapped(MigrationProcessorClient.MigrationScheduleModel)
        case executeNextTransferTapped
        case restartTapped
        case completionAcknowledgeTapped
    }

    // MARK: - Dependencies

    @Dependency(\.migrationProcessor) var migrationProcessor

    // MARK: - Body

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .merge(
                    .publisher {
                        migrationProcessor.observe()
                            .map(Action.processorStateChanged)
                    }
                    .cancellable(id: state.cancelId, cancelInFlight: true),
                    .run { _ in migrationProcessor.refresh() }
                )

            case .onDisappear:
                return .cancel(id: state.cancelId)

            case .processorStateChanged(let phase):
                state.phase = phase
                // When we transition into InProgress, automatically attempt the next transfer.
                // This gives the "each app open advances migration" behaviour of Approach B.
                if case .inProgress = phase {
                    return .run { [torEnabled = state.torEnabled] _ in
                        migrationProcessor.executeNextTransfer(torEnabled)
                    }
                }
                return .none

            case .torToggled(let enabled):
                state.torEnabled = enabled
                return .none

            case .noteSplitConfirmTapped(let proposal):
                return .run { _ in migrationProcessor.confirmNoteSplit(proposal) }

            case .scheduleConfirmTapped(let schedule):
                return .run { _ in migrationProcessor.confirmSchedule(schedule) }

            case .executeNextTransferTapped:
                return .run { [torEnabled = state.torEnabled] _ in
                    migrationProcessor.executeNextTransfer(torEnabled)
                }

            case .restartTapped:
                return .run { _ in migrationProcessor.restart() }

            case .completionAcknowledgeTapped:
                // Phase will move to .notStarted on next refresh (no Orchard balance remaining).
                return .run { _ in migrationProcessor.refresh() }
            }
        }
    }
}
