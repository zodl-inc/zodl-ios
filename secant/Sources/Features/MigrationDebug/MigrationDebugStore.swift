//
//  MigrationDebugStore.swift
//  zodl
//
//  PROTOTYPE / DEBUG: drives the dummy migration engine so every state can be reproduced on demand,
//  and runs the real background-task code path ("Run background task now") without waiting on iOS.
//

import ComposableArchitecture
import SwiftUI
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationDebug {
    @ObservableState
    struct State: Equatable {
        var snapshot = ""
        var orchardZec = "12.458"
        var noteCount = 5
        var advanceBlocks = 100

        init() { }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case onAppear
        case refresh
        case snapshotLoaded(String)
        case resetTapped
        case seedTapped
        case advanceHeightTapped
        case confirmSplitTapped
        case runBackgroundTaskTapped
        case armNextResult(TransferResult)
        case jumpTo(MigrationDebugTarget)
    }

    @Dependency(\.migrationSDK) var migrationSDK

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .onAppear, .refresh:
                return .run { [migrationSDK] send in
                    await send(.snapshotLoaded(migrationSDK.debug.snapshotDescription()))
                }

            case let .snapshotLoaded(snapshot):
                state.snapshot = snapshot
                return .none

            case .resetTapped:
                return .run { [migrationSDK] send in
                    await migrationSDK.debug.reset()
                    await send(.refresh)
                }

            case .seedTapped:
                let zats = Int64((Double(state.orchardZec) ?? 0) * 100_000_000)
                let count = state.noteCount
                return .run { [migrationSDK] send in
                    await migrationSDK.debug.seed(Zatoshi(zats), count)
                    await send(.refresh)
                }

            case .advanceHeightTapped:
                let blocks = state.advanceBlocks
                return .run { [migrationSDK] send in
                    await migrationSDK.debug.advanceHeight(blocks)
                    await send(.refresh)
                }

            case .confirmSplitTapped:
                return .run { [migrationSDK] send in
                    await migrationSDK.debug.confirmSplitNow()
                    await send(.refresh)
                }

            case .runBackgroundTaskTapped:
                return .run { send in
                    let worker = MigrationBackgroundWorker()
                    await worker.runMigrationStep()
                    await send(.refresh)
                }

            case let .armNextResult(result):
                return .run { [migrationSDK] send in
                    await migrationSDK.debug.armNextTransferResult(result)
                    await send(.refresh)
                }

            case let .jumpTo(target):
                return .run { [migrationSDK] send in
                    await migrationSDK.debug.jumpTo(target)
                    await send(.refresh)
                }

            case .binding:
                return .none
            }
        }
    }
}
