//
//  MigrationImmediateReviewStore.swift
//  zodl
//
//  "Review Transfer" → "Sending…" → "Sent!" for the Migrate Immediately path. A single transfer is
//  proposed, signed, and broadcast in the foreground (no background task).
//

import ComposableArchitecture
import SwiftUI
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationImmediateReview {
    @ObservableState
    struct State: Equatable {
        enum Step: Equatable {
            case review
            case sending
            case sent
            case failed
        }

        var step: Step = .review
        var amount: Zatoshi = .zero
        var fee: Zatoshi = .zero
        var txId = ""
        var networkPrivacy = NetworkPrivacyOptions(useTor: false)
        var schedule: MigrationSchedule?

        init() { }
    }

    enum Action {
        enum Delegate: Equatable {
            case finished
        }

        case onAppear
        case scheduleLoaded(MigrationSchedule)
        case confirmTapped
        case executed(TransferResult?)
        case doneTapped
        case delegate(Delegate)
    }

    @Dependency(\.migrationSDK) var migrationSDK

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { send in
                    await send(.scheduleLoaded(migrationSDK.proposeImmediateMigrationTransfers()))
                }

            case let .scheduleLoaded(schedule):
                state.schedule = schedule
                state.amount = schedule.transfers.first?.amount ?? migrationSDK.simulatedOrchardBalance()
                return .none

            case .confirmTapped:
                guard let schedule = state.schedule else { return .none }
                state.step = .sending
                let options = state.networkPrivacy
                return .run { send in
                    await migrationSDK.signAndStoreMigrationSchedule(schedule)
                    let result = await migrationSDK.executeNextPendingTransfer(options)
                    await send(.executed(result))
                }

            case let .executed(result):
                if case let .success(txId) = result {
                    state.txId = txId
                    state.step = .sent
                } else {
                    state.step = .failed
                }
                return .none

            case .doneTapped:
                return .send(.delegate(.finished))

            case .delegate:
                return .none
            }
        }
    }
}
