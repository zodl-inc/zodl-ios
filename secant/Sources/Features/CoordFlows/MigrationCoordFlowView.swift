//
//  MigrationCoordFlowView.swift
//  Zashi
//
//  NavigationStack for the Orchard -> Ironwood migration flow (MOB-1466). `MigrationEntry` is the
//  root screen; every other migration screen is pushed onto `path` by the coordinator.
//
//  MOB-1478 (W2): the Tor bottom sheet is a coordinator-owned `zashiSheet`, not a `path` element —
//  presented from either Entry (immediate) or How This Works (scheduled) via the coordinator's shared
//  gate, mirroring the `ServerSetup`/`serverSetupViewBinding` precedent in `RootView`.
//

import SwiftUI
import ComposableArchitecture

struct MigrationCoordFlowView: View {
    @Perception.Bindable var store: StoreOf<MigrationCoordFlow>

    init(store: StoreOf<MigrationCoordFlow>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                MigrationEntryView(
                    store:
                        store.scope(
                            state: \.entryState,
                            action: \.entry
                        )
                )
            } destination: { store in
                switch store.case {
                case let .backgroundDelivery(store):
                    MigrationBackgroundDeliveryView(store: store)
                case let .complete(store):
                    MigrationCompleteView(store: store)
                case let .howItWorks(store):
                    MigrationHowItWorksView(store: store)
                case let .keystoneSign(store):
                    MigrationKeystoneSignView(store: store)
                case let .noteSplit(store):
                    MigrationNoteSplitView(store: store)
                case let .notifications(store):
                    MigrationNotificationsView(store: store)
                case let .recovery(store):
                    MigrationRecoveryView(store: store)
                case let .reviewTransfer(store):
                    MigrationReviewTransferView(store: store)
                case let .scan(store):
                    ScanView(store: store)
                case let .scheduled(store):
                    MigrationScheduledView(store: store)
                case let .sending(store):
                    MigrationSendingView(store: store)
                case let .status(store):
                    MigrationStatusView(store: store)
                case let .transferPlan(store):
                    MigrationTransferPlanView(store: store)
                }
            }
            .zashiSheet(
                isPresented: Binding(
                    get: { store.isTorSheetPresented },
                    set: { store.send(.torSheetPresentationChanged($0)) }
                )
            ) {
                MigrationTorSheetView(store: store.scope(state: \.torSheetState, action: \.torSheet))
            }
        }
        .applyScreenBackground()
        .onAppear {
            store.send(.onAppear)
        }
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

#Preview {
    NavigationView {
        MigrationCoordFlowView(store: MigrationCoordFlow.placeholder)
    }
}
