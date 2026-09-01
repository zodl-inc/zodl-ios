#if VOTING_ENABLED && ZODL_INTERNAL
import SwiftUI
import ComposableArchitecture

/// Diagnostics for the delegation recovery, and the button that runs it.
///
/// Deliberately shows before it acts. The recovery reads files nobody can
/// inspect on a device, and its whole purpose is to tell a wiped round from an
/// intact one, so the screen states which copies exist, what each one holds,
/// and what pressing the button would change.
@Reducer
struct DelegationRecovery {
    @ObservableState
    struct State: Equatable {
        var inspection: DelegationRecoveryInspection?
        var isInspecting = false
        var isRecovering = false
        /// Result of the last run, kept on screen rather than shown in an
        /// alert that has to be dismissed before the numbers can be compared.
        var report: DelegationRecoveryReport?

        init() { }
    }

    enum Action: Equatable {
        case onAppear
        case inspectionLoaded(DelegationRecoveryInspection)
        case recoverTapped
        case recoveryFinished(DelegationRecoveryReport)
        case refreshTapped
    }

    @Dependency(\.delegationRecovery) var delegationRecovery

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear, .refreshTapped:
                guard !state.isInspecting else {
                    LoggerProxy.info("[poll-recovery] screen: inspect already in flight")
                    return .none
                }
                state.isInspecting = true
                LoggerProxy.info(
                    "[poll-recovery] screen: \(action == .onAppear ? "opened" : "refresh tapped"), reading databases"
                )
                return .run { send in
                    await send(.inspectionLoaded(await delegationRecovery.inspect()))
                }

            case let .inspectionLoaded(inspection):
                state.isInspecting = false
                state.inspection = inspection
                LoggerProxy.info(
                    "[poll-recovery] screen: showing \(inspection.sources.count) copy/copies, "
                    + "needsRecovery=\(inspection.needsRecovery), "
                    + "restorable=\(inspection.restorableBundles)"
                )
                return .none

            case .recoverTapped:
                guard !state.isRecovering else {
                    LoggerProxy.info("[poll-recovery] screen: run already in flight")
                    return .none
                }
                state.isRecovering = true
                state.report = nil
                LoggerProxy.info("[poll-recovery] screen: Run recovery tapped")
                return .run { send in
                    await send(.recoveryFinished(await delegationRecovery.run()))
                }

            case let .recoveryFinished(report):
                state.isRecovering = false
                state.report = report
                LoggerProxy.info(
                    "[poll-recovery] screen: run finished, outcome=\(report.outcome), "
                    + "escrowed=\(report.bundlesEscrowed); re-reading to show the new state"
                )
                // Re-read, so the screen shows the state the run left behind
                // rather than the one it was launched from.
                return .run { send in
                    await send(.inspectionLoaded(await delegationRecovery.inspect()))
                }
            }
        }
    }
}
#endif
