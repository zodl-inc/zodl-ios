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
            // MOB-1510: the Keystone minimum-firmware gate — `KeystoneFirmwareUpdateContent` is the
            // same illustration/title/body `KeystoneFirmwareUpdateView` shows on the send-side
            // coordinators' full-screen path push; there is no `SendConfirmation` in this flow to
            // scope that view's store from, so the content is presented directly here instead,
            // mirroring the Tor sheet's own coordinator-owned-sheet idiom above.
            .zashiSheet(
                isPresented: Binding(
                    get: { store.isKeystoneFirmwareUpdatePresented },
                    set: { store.send(.keystoneFirmwareUpdatePresentationChanged($0)) }
                )
            ) {
                VStack(spacing: 0) {
                    KeystoneFirmwareUpdateContent(detectedVersion: store.detectedKeystoneFirmware)
                        .padding(.top, 24)

                    ZashiButton(String(localizable: .keystoneFirmwareUpdateClose)) {
                        store.send(.keystoneFirmwareUpdatePresentationChanged(false))
                    }
                    .padding(.top, 32)
                    .padding(.bottom, Design.Spacing.sheetBottomSpace)
                }
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
