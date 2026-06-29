//
//  MigrationTransferPlanStore.swift
//  zodl
//
//  "Transfer Plan" — proposes the full schedule for review, then on confirm signs+stores it, requests
//  notification authorization, and schedules the first background run.
//

import ComposableArchitecture
import SwiftUI
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationTransferPlan {
    @ObservableState
    struct State: Equatable {
        var schedule: MigrationSchedule?
        var networkPrivacy = NetworkPrivacyOptions(useTor: false)
        var isLoading = true
        var isCommitting = false

        init() { }
    }

    enum Action {
        enum Delegate: Equatable {
            case scheduled
        }

        case onAppear
        case scheduleLoaded(MigrationSchedule)
        case confirmTapped
        case committed
        case delegate(Delegate)
    }

    @Dependency(\.migrationSDK) var migrationSDK
    @Dependency(\.migrationBGScheduler) var migrationBGScheduler
    @Dependency(\.localNotification) var localNotification

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.isLoading = true
                return .run { send in
                    await send(.scheduleLoaded(migrationSDK.proposeMigrationTransfers()))
                }

            case let .scheduleLoaded(schedule):
                state.schedule = schedule
                state.isLoading = false
                return .none

            case .confirmTapped:
                guard let schedule = state.schedule else { return .none }
                state.isCommitting = true
                let options = state.networkPrivacy
                return .run { send in
                    await migrationSDK.signAndStoreMigrationSchedule(schedule)
                    _ = await localNotification.requestAuthorization()
                    migrationBGScheduler.scheduleFirstRun()
                    _ = options
                    await send(.committed)
                }

            case .committed:
                state.isCommitting = false
                return .send(.delegate(.scheduled))

            case .delegate:
                return .none
            }
        }
    }
}
