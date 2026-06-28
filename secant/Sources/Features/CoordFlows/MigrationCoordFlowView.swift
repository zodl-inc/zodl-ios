//
//  MigrationCoordFlowView.swift
//  zodl
//

import SwiftUI
import ComposableArchitecture

struct MigrationCoordFlowView: View {
    @Perception.Bindable var store: StoreOf<MigrationCoordFlow>
    let tokenName: String

    init(store: StoreOf<MigrationCoordFlow>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                MigrationEntryView(
                    store: store.scope(state: \.entryState, action: \.entry),
                    tokenName: tokenName
                )
                .navigationBarHidden(true)
            } destination: { store in
                switch store.case {
                case let .noteSplit(store):
                    MigrationNoteSplitView(store: store, tokenName: tokenName)
                case let .backgroundDelivery(store):
                    MigrationBackgroundDeliveryView(store: store, tokenName: tokenName)
                case let .networkPrivacy(store):
                    MigrationNetworkPrivacyView(store: store, tokenName: tokenName)
                case let .transferPlan(store):
                    MigrationTransferPlanView(store: store, tokenName: tokenName)
                case let .status(store):
                    MigrationStatusView(store: store, tokenName: tokenName)
                case let .immediateReview(store):
                    MigrationImmediateReviewView(store: store, tokenName: tokenName)
                case let .recovery(store):
                    MigrationRecoveryView(store: store, tokenName: tokenName)
                }
            }
            .onAppear { self.store.send(.start) }
        }
        .applyScreenBackground()
    }
}

// MARK: - Placeholders

extension MigrationCoordFlow.State {
    static var initial: MigrationCoordFlow.State { MigrationCoordFlow.State() }
}

extension MigrationCoordFlow {
    @MainActor static let placeholder = StoreOf<MigrationCoordFlow>(
        initialState: .initial
    ) {
        MigrationCoordFlow()
    }
}
