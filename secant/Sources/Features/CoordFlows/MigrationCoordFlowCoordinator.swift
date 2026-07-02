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
                    // Invalid / expired transfer → C5 "Transfer No Longer Valid" (recreate + reschedule).
                    state.path.append(.recovery(MigrationRecovery.State()))
                } else if migrationSDK.hasOverdueTransfers() {
                    // Stalled / overdue (failed or missed send) → the status screen renders "Resume Migration".
                    state.path.append(.status(MigrationStatus.State(presentation: .progress)))
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
                    // Private path denominates the balance into multiple transfers, which requires a
                    // note split (one Orchard note per denomination) first. The split fans the balance
                    // into same-address V2 change outputs — the one V2-retaining operation the
                    // post-NU6.3 cross-address restriction sanctions.
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
                // Done on the "Migration Complete" (C6) screen acknowledges completion so the Home
                // SmartBanner stops showing the completion state.
                if migrationSDK.getMigrationState() == .complete {
                    migrationSDK.acknowledgeMigrationComplete()
                }
                return .send(.dismiss)

            case .path(.element(id: _, action: .immediateReview(.delegate(.finished)))):
                // The immediate path also ends in `.complete` — acknowledge so the banner stops showing.
                if migrationSDK.getMigrationState() == .complete {
                    migrationSDK.acknowledgeMigrationComplete()
                }
                return .send(.dismiss)

            // ── Resume Migration (stalled) actions, on the status screen ──
            case .path(.element(id: _, action: .status(.delegate(.sendNow)))):
                // Broadcast the stalled transfer now; the status screen refreshes from the state stream.
                return .run { [migrationSDK] _ in
                    _ = await migrationSDK.executeNextPendingTransfer(NetworkPrivacyOptions(useTor: false))
                }

            case .path(.element(id: _, action: .status(.delegate(.reschedule)))):
                return .run { [migrationSDK, migrationBGScheduler] _ in
                    await migrationSDK.rescheduleStalledTransfer()
                    // The schedule was re-created — reset the background cadence (first run ~1 h out).
                    migrationBGScheduler.scheduleFirstRun()
                }

            // ── Recovery (C5 · invalid) ──
            case .path(.element(id: _, action: .recovery(.delegate(.close)))):
                // Deep-entry screen: the leading close control closes the whole flow → Home.
                return .send(.dismiss)

            case .path(.element(id: _, action: .recovery(.delegate(.recreate)))):
                return .run { [migrationSDK, migrationBGScheduler] send in
                    await migrationSDK.recreateInvalidTransfer()
                    // The schedule was re-created — reset the background cadence (first run ~1 h out).
                    migrationBGScheduler.scheduleFirstRun()
                    await send(.recoveryRecreated)
                }

            case .recoveryRecreated:
                state.path.append(.status(MigrationStatus.State(presentation: .progress)))
                return .none

            default:
                return .none
            }
        }
    }
}
