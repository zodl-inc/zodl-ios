//
//  MigrationCoordFlowStore.swift
//  zodl
//
//  Coordinator for the Orchard → Ironwood migration. Root screen is MigrationEntry; subsequent
//  screens live on a navigation stack. Child screens emit delegate actions; the coordinator owns all
//  navigation (see MigrationCoordFlowCoordinator).
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationCoordFlow {
    @Reducer
    enum Path {
        case noteSplit(MigrationNoteSplit)
        case backgroundDelivery(MigrationBackgroundDelivery)
        case networkPrivacy(MigrationNetworkPrivacy)
        case transferPlan(MigrationTransferPlan)
        case status(MigrationStatus)
        case immediateReview(MigrationImmediateReview)
        case recovery(MigrationRecovery)
    }

    @ObservableState
    struct State {
        var path = StackState<Path.State>()
        var entryState = MigrationEntry.State()
        var mode: MigrationMode = .privateScheduled

        init() { }
    }

    enum Action {
        case path(StackActionOf<Path>)
        case entry(MigrationEntry.Action)
        /// Sent when the flow appears — routes to recovery/progress if a migration is already underway.
        case start
        /// Internal follow-up for async recovery handling.
        case recoveryRecreated
        /// Bubbles up to Root, which pops the whole flow.
        case dismiss
    }

    @Dependency(\.migrationSDK) var migrationSDK
    @Dependency(\.migrationBGScheduler) var migrationBGScheduler

    init() { }

    var body: some Reducer<State, Action> {
        coordinatorReduce()

        Scope(state: \.entryState, action: \.entry) {
            MigrationEntry()
        }

        Reduce { _, action in
            switch action {
            default: return .none
            }
        }
        .forEach(\.path, action: \.path)
    }
}
