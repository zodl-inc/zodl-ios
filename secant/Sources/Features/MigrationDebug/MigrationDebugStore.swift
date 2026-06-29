//
//  MigrationDebugStore.swift
//  zodl
//
//  PROTOTYPE / DEBUG: drives the dummy migration engine so every state can be reproduced on demand,
//  and runs the real background-task code path ("Run background task now") without waiting on iOS.
//  Every action reports what it did via a feedback alert — so an armed result that is otherwise a
//  silent retry (e.g. a network error) is observable.
//

import ComposableArchitecture
import SwiftUI
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationDebug {
    @ObservableState
    struct State: Equatable {
        @Presents var alert: AlertState<Action.Alert>?
        var snapshot = ""
        var orchardZec = "12.458"
        var noteCount = 5
        var advanceBlocks = 100
        var runLog: [MigrationBackgroundRun] = []

        init() { }
    }

    enum Action: BindableAction, Equatable {
        case alert(PresentationAction<Alert>)
        case binding(BindingAction<State>)
        case onAppear
        case refresh
        case snapshotLoaded(String)
        case logLoaded([MigrationBackgroundRun])
        case resetTapped
        case seedTapped
        case advanceHeightTapped
        case confirmSplitTapped
        case runBackgroundTaskTapped
        case backgroundTaskFinished(MigrationStepOutcome)
        case armNextResult(TransferResult)
        case jumpTo(MigrationDebugTarget)
        case clearLogTapped
        /// Presents a one-button feedback alert with the given title + message.
        case report(title: String, message: String)

        /// No alert button does anything beyond dismiss.
        enum Alert: Equatable { }
    }

    @Dependency(\.migrationSDK) var migrationSDK

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .onAppear, .refresh:
                return .run { [migrationSDK] send in
                    await send(.snapshotLoaded(migrationSDK.debug.snapshotDescription()))
                    await send(.logLoaded(migrationSDK.backgroundRunLog()))
                }

            case let .snapshotLoaded(snapshot):
                state.snapshot = snapshot
                return .none

            case let .logLoaded(entries):
                state.runLog = entries
                return .none

            case .resetTapped:
                return .run { [migrationSDK] send in
                    await migrationSDK.debug.reset()
                    await send(.refresh)
                    await send(.report(title: "Reset", message: "Migration reset to the seeded default."))
                }

            case .seedTapped:
                let zecText = state.orchardZec
                let zats = Int64((Double(state.orchardZec) ?? 0) * 100_000_000)
                let count = state.noteCount
                return .run { [migrationSDK] send in
                    await migrationSDK.debug.seed(Zatoshi(zats), count)
                    await send(.refresh)
                    await send(.report(title: "Seeded", message: "Seeded \(zecText) ZEC with note count \(count)."))
                }

            case .advanceHeightTapped:
                let blocks = state.advanceBlocks
                return .run { [migrationSDK] send in
                    await migrationSDK.debug.advanceHeight(blocks)
                    await send(.refresh)
                    await send(.report(title: "Advanced", message: "Advanced block height by \(blocks) blocks."))
                }

            case .confirmSplitTapped:
                return .run { [migrationSDK] send in
                    await migrationSDK.debug.confirmSplitNow()
                    await send(.refresh)
                    await send(.report(title: "Split confirmed", message: "The pending note split was confirmed."))
                }

            case .runBackgroundTaskTapped:
                return .run { send in
                    let worker = MigrationBackgroundWorker()
                    let outcome = await worker.runMigrationStep(trigger: .manual)
                    await send(.refresh)
                    await send(.backgroundTaskFinished(outcome))
                }

            case let .backgroundTaskFinished(outcome):
                return .send(.report(title: "Background task", message: Self.message(for: outcome)))

            case let .armNextResult(result):
                let label = Self.label(for: result)
                return .run { [migrationSDK] send in
                    await migrationSDK.debug.armNextTransferResult(result)
                    await send(.refresh)
                    await send(.report(
                        title: "Armed",
                        message: "The next transfer attempt will return: \(label)."
                    ))
                }

            case let .jumpTo(target):
                let label = Self.label(for: target)
                return .run { [migrationSDK] send in
                    await migrationSDK.debug.jumpTo(target)
                    await send(.refresh)
                    await send(.report(title: "Jumped", message: "Forced state: \(label)."))
                }

            case .clearLogTapped:
                return .run { [migrationSDK] send in
                    migrationSDK.clearBackgroundRunLog()
                    await send(.refresh)
                    await send(.report(title: "Log cleared", message: "Background task log cleared."))
                }

            case let .report(title, message):
                state.alert = AlertState {
                    TextState(title)
                } actions: {
                    ButtonState(role: .cancel) { TextState("OK") }
                } message: {
                    TextState(message)
                }
                return .none

            case .alert:
                return .none

            case .binding:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    // MARK: - Human-readable descriptions

    private static func message(for outcome: MigrationStepOutcome) -> String {
        switch outcome {
        case .syncRequired:
            return "Sync is required before the next transfer — the background task was skipped (by design, sync never runs inside it)."
        case .nothingPending:
            return "No pending transfer to execute. Migration is finished or hasn't started."
        case .tooSoonAfterActivity:
            return "Too soon after the last app activity — a scheduled run would skip and reschedule past the 1-hour gap. (The debug button bypasses this and sends immediately.)"
        case let .result(result):
            switch result {
            case let .success(txId):
                return "Transfer broadcast ✓\n\(txId)"
            case let .networkError(retryable):
                return "Network error\(retryable ? " (retryable)" : "") — migration paused. The transfer now needs attention; open the migration flow to resume (Send now / Reschedule)."
            case .invalidNote:
                return "Invalid note — migration now requires attention."
            case .expired:
                return "Transfer expired — migration now requires attention."
            }
        }
    }

    private static func label(for result: TransferResult) -> String {
        switch result {
        case .success:
            return "Success"
        case let .networkError(retryable):
            return "Network error\(retryable ? " (retryable)" : "")"
        case .invalidNote:
            return "Invalid note"
        case .expired:
            return "Expired"
        }
    }

    private static func label(for target: MigrationDebugTarget) -> String {
        switch target {
        case .overdue:
            return "Overdue"
        case .invalidTransfer:
            return "Requires attention (invalid)"
        case .syncRequired:
            return "Sync required"
        case .complete:
            return "Complete"
        case .completeWithDust:
            return "Complete with dust"
        }
    }
}
