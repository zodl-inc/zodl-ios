//
//  MigrationCoordFlowView.swift
//  Zodl
//
//  NavigationStack for the Orchard -> Ironwood migration flow. `MigrationEntry` is the root screen;
//  every other migration screen is pushed onto `path` by the coordinator.
//
//  PHASE 2: #1930's coordinator-owned sheets (the Tor bottom sheet, the Keystone minimum-firmware
//  gate) and its expired-recovery alert are absent along with the phases that own them — see
//  `MigrationCoordFlowStore.swift`. The structure is otherwise #1930's verbatim.
//

import SwiftUI
import ComposableArchitecture

struct MigrationCoordFlowView: View {
    @PlatformBindable var store: StoreOf<MigrationCoordFlow>

    init(store: StoreOf<MigrationCoordFlow>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                // Held blank unless re-entry routing chose the fork — a pushed destination keeps
                // this root hidden for the flow's whole life (`State.isReentryResolved`). Entry is
                // this stack's ROOT, so rendering it eagerly flashed the "privately or manually?"
                // fork on every committed run — offering a choice already made, and tappable while
                // it showed. The pause is the same wait either way; it just no longer asserts a
                // state the app has not established.
                if store.isReentryResolved {
                    MigrationEntryView(
                        store:
                            store.scope(
                                state: \.entryState,
                                action: \.entry
                            )
                    )
                } else {
                    // A SPINNER, not a blank. Holding the root back removed the fork flash but
                    // replaced it with an empty screen for however long re-entry takes — and on a
                    // device that turned out to be up to ~15 s, because the hydrating reads queue
                    // behind the migration proving work on the same DB actor. Fifteen seconds of
                    // nothing reads as a hang; fifteen seconds of a spinner reads as work. Neither
                    // is good, and the duration itself is tracked separately (handover O2) — but of
                    // the two, only one lies about what the app is doing.
                    VStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .background(Asset.Colors.background.color)
                }
            } destination: { store in
                switch store.case {
                case let .complete(store):
                    MigrationCompleteView(store: store)
                case let .howItWorks(store):
                    MigrationHowItWorksView(store: store)
                case let .recovery(store):
                    MigrationRecoveryView(store: store)
                case let .keystoneSign(store):
                    MigrationKeystoneSignView(store: store)
                case let .notifications(store):
                    MigrationNotificationsView(store: store)
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
            // `$store.<flag>` rather than a hand-rolled `Binding(get:set:)`: SwiftUI invokes a
            // hand-rolled binding's `get` during ITS update cycle, outside the
            // `WithPerceptionTracking` scope this body established, which trips "Perceptible state
            // was accessed but is not being tracked" on EVERY screen this coordinator hosts — not
            // just the one owning the sheet. The side effects survive: see
            // `.binding(\.isTorSheetPresented)` in the coordinator.
            .zashiSheet(isPresented: $store.isTorSheetPresented) {
                MigrationTorSheetView(store: store.scope(state: \.torSheetState, action: \.torSheet))
            }
            // PHASE 7: the migration Keystone minimum-firmware gate. Mirrors
            // `KeystoneFirmwareUpdateContent`'s illustration/title/body/button structure (the
            // single-transaction flow's own firmware gate) but with its OWN copy and PER-CEREMONY
            // floor: the batch ceremony trips on the decode envelope's version against 3.0.2, the
            // immediate single-PCZT ceremony on the PCZT stamp against the production floor.
            // `keystoneFirmwareGateMinimumVersion` records whichever applied, so the copy always
            // reports the right required version. Presented directly here rather than scoped from a
            // `SendConfirmation` store (there is none in this flow), mirroring the Tor sheet's
            // coordinator-owned-sheet idiom above.
            .zashiSheet(isPresented: $store.isKeystoneFirmwareGatePresented) {
                // The content builder is evaluated at PRESENTATION time, outside this body's
                // tracking scope, and it reads store state (`keystoneFirmwareGateBody`) — so it
                // needs a tracking scope of its own.
                WithPerceptionTracking {
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
            }
        }
        .applyScreenBackground()
        .onAppear {
            store.send(.onAppear)
        }
    }

    /// Mirrors `KeystoneFirmwareUpdateContent.bodyText`'s specific/legacy split: a
    /// detected-but-too-low version interpolates both figures, an undetected one (the envelope or
    /// stamp reported none at all) falls back to the floor-only variant. The interpolated minimum is
    /// the floor the FAILED gate actually checked; the batch constant is only a defensive fallback.
    private var keystoneFirmwareGateBody: String {
        let minimumVersion = store.keystoneFirmwareGateMinimumVersion
            ?? MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware.versionString
        if let detected = store.detectedKeystoneFirmwareVersion {
            return String(localizable: .migrationKeystoneFirmwareBody(detected, minimumVersion))
        }
        return String(localizable: .migrationKeystoneFirmwareLegacyBody(minimumVersion))
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
