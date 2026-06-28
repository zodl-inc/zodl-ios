//
//  MigrationCoordFlowCoordinator.swift
//  zodl
//
//  All navigation for the migration flow. Listens to child delegate actions and pushes the next
//  screen; runs the cross-screen SDK orchestration that isn't owned by a single screen.
//

import ComposableArchitecture
import Foundation

extension MigrationCoordFlow {
    func coordinatorReduce() -> Reduce<MigrationCoordFlow.State, MigrationCoordFlow.Action> {
        Reduce { state, action in
            switch action {
            // ── Flow start: jump straight to the relevant screen if a migration is underway ──
            case .start:
                guard state.path.isEmpty else { return .none }
                if migrationSDK.hasInvalidTransfers() {
                    state.path.append(.recovery(MigrationRecovery.State(kind: .invalid)))
                } else if migrationSDK.hasOverdueTransfers() {
                    state.path.append(.recovery(MigrationRecovery.State(kind: .overdue)))
                } else {
                    switch migrationSDK.getMigrationState() {
                    case .inProgress, .complete:
                        // Both render on the status screen (which shows the Complete summary when done).
                        state.path.append(.status(MigrationStatus.State(presentation: .progress)))
                    case .splitPendingConfirmation:
                        state.path.append(.noteSplit(MigrationNoteSplit.State()))
                    default:
                        break
                    }
                }
                return .none

            // ── Entry choice ──
            case let .entry(.delegate(.chose(mode))):
                state.mode = mode
                // Record the choice in the engine FIRST, so isNoteSplitNeeded() reflects it.
                migrationSDK.selectMigrationMode(mode)
                if mode == .immediate {
                    state.path.append(.networkPrivacy(MigrationNetworkPrivacy.State()))
                } else if migrationSDK.isNoteSplitNeeded() {
                    state.path.append(.noteSplit(MigrationNoteSplit.State()))
                } else {
                    state.path.append(.backgroundDelivery(MigrationBackgroundDelivery.State()))
                }
                return .none

            case .entry(.delegate(.close)):
                return .send(.dismiss)

            // ── Private path navigation ──
            case .path(.element(id: _, action: .noteSplit(.delegate(.continued)))):
                state.path.append(.backgroundDelivery(MigrationBackgroundDelivery.State()))
                return .none

            case .path(.element(id: _, action: .backgroundDelivery(.delegate(.continued)))):
                state.path.append(.networkPrivacy(MigrationNetworkPrivacy.State()))
                return .none

            case let .path(.element(id: _, action: .networkPrivacy(.delegate(.confirmed(options))))):
                if state.mode == .immediate {
                    var review = MigrationImmediateReview.State()
                    review.networkPrivacy = options
                    state.path.append(.immediateReview(review))
                } else {
                    var plan = MigrationTransferPlan.State()
                    plan.networkPrivacy = options
                    state.path.append(.transferPlan(plan))
                }
                return .none

            case .path(.element(id: _, action: .transferPlan(.delegate(.scheduled)))):
                state.path.append(.status(MigrationStatus.State(presentation: .scheduledSuccess)))
                return .none

            // ── Terminal screens ──
            case .path(.element(id: _, action: .status(.delegate(.done)))):
                return .send(.dismiss)

            case .path(.element(id: _, action: .immediateReview(.delegate(.finished)))):
                return .send(.dismiss)

            // ── Recovery ──
            case .path(.element(id: _, action: .recovery(.delegate(.close)))):
                // Deep-entry screen: the leading back control closes the whole flow → Home.
                return .send(.dismiss)

            case .path(.element(id: _, action: .recovery(.delegate(.recreate)))):
                return .run { [migrationSDK] send in
                    _ = await migrationSDK.restartCurrentMigrationStep()
                    await send(.recoveryRecreated)
                }

            case .recoveryRecreated:
                state.path.append(.transferPlan(MigrationTransferPlan.State()))
                return .none

            case .path(.element(id: _, action: .recovery(.delegate(.sendNow)))):
                return .run { [migrationSDK] send in
                    _ = await migrationSDK.executeNextPendingTransfer(NetworkPrivacyOptions(useTor: false))
                    await send(.recoverySent)
                }

            case .recoverySent:
                migrationBGScheduler.scheduleNextRun(60)
                state.path.append(.status(MigrationStatus.State(presentation: .progress)))
                return .none

            case .path(.element(id: _, action: .recovery(.delegate(.reschedule)))):
                migrationBGScheduler.scheduleNextRun(60)
                state.path.append(.status(MigrationStatus.State(presentation: .progress)))
                return .none

            default:
                return .none
            }
        }
    }
}
