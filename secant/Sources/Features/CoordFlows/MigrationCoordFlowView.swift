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
            // MOB-1513: the migration Keystone minimum-firmware gate. Mirrors
            // `KeystoneFirmwareUpdateContent`'s illustration/title/body/button structure (the
            // single-transaction Keystone flow's own firmware-gate content, `Features/
            // SendConfirmation/KeystoneFirmwareUpdateView.swift`) but with its OWN copy and
            // per-ceremony floor (MOB-1513 R8): the batch ceremony trips on
            // `KeystoneBatchDecodeResult.firmwareVersion` from the decode envelope against 3.0.2,
            // the immediate single-PCZT ceremony on the production PCZT stamp against 3.0.0 —
            // `keystoneFirmwareGateMinimumVersion` records whichever applied, so the copy always
            // reports the right required version. There is no `SendConfirmation` in this flow to
            // scope that view's store from either, so the content is presented directly here,
            // mirroring the Tor sheet's own coordinator-owned-sheet idiom above.
            .zashiSheet(
                isPresented: Binding(
                    get: { store.isKeystoneFirmwareGatePresented },
                    set: { store.send(.keystoneFirmwareGatePresentationChanged($0)) }
                )
            ) {
                VStack(spacing: 0) {
                    Asset.Assets.Illustrations.failure3.image
                        .resizable()
                        .frame(width: 148, height: 148)
                        .padding(.top, 24)

                    Text(String(localizable: .migrationKeystoneFirmwareTitle))
                        .zFont(.semiBold, size: 28, style: Design.Text.primary)
                        .padding(.top, 16)

                    Text(keystoneFirmwareGateBody)
                        .zFont(size: 14, style: Design.Text.primary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(1.5)
                        .screenHorizontalPadding()

                    ZashiButton(String(localizable: .migrationKeystoneFirmwareClose)) {
                        store.send(.keystoneFirmwareGatePresentationChanged(false))
                    }
                    .padding(.top, 32)
                    .padding(.bottom, Design.Spacing.sheetBottomSpace)
                }
            }
            // MOB-1458 (Task 2): the expired-recovery refresh-failure alert (restart-or-cancel).
            .alert($store.scope(state: \.alert, action: \.alert))
        }
        .applyScreenBackground()
        .onAppear {
            store.send(.onAppear)
        }
    }

    /// MOB-1513: mirrors `KeystoneFirmwareUpdateContent.bodyText`'s specific/legacy split — a
    /// detected-but-too-low version interpolates both figures, an undetected one (the envelope or
    /// stamp reported none at all) falls back to the floor-only variant. MOB-1513 (R8): the
    /// interpolated minimum is the floor the FAILED gate actually checked
    /// (`keystoneFirmwareGateMinimumVersion` — batch envelope 3.0.2 vs the immediate single-PCZT
    /// ceremony's production stamp floor 3.0.0); the batch constant is only a defensive fallback.
    private var keystoneFirmwareGateBody: String {
        let minimumVersion = store.keystoneFirmwareGateMinimumVersion
            ?? MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware.versionString
        if let detected = store.detectedKeystoneFirmwareVersion {
            return String(
                localizable: .migrationKeystoneFirmwareBody(
                    detected,
                    minimumVersion
                )
            )
        }
        return String(
            localizable: .migrationKeystoneFirmwareLegacyBody(
                minimumVersion
            )
        )
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
