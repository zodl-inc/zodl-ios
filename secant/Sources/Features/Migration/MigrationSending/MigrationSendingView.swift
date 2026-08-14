//
//  MigrationSendingView.swift
//  zodl
//
//  "Sending" / "Sent" screen (MOB-1463, Figma S8 · sending 2618:6858 / sent 2618:6895). `onAppear`
//  drives the store's sequential transfer execution (MOB-1466). The `closeTapped` /
//  `viewTransactionTapped` delegates (`.closed` / `.viewTransaction`) are consumed by
//  `MigrationCoordFlowCoordinator` and `RootCoordinator` respectively (phase 3).
//
//  Also reused for the "Migrate anyway" dust lane (MOB-1487). MOB-1494 (round 4): every lane
//  shows the same "migrated" subtitles (the canvas dropped the "sent" wording), so the view has
//  no per-lane copy switching any more.
//
//  2026-08-07 (Lukas): the `.waiting(target:)` phase (the send-now lane's countdown + Cancel) and
//  the `isManualStepLane` subtitle fork retired with the whole manual-tap send surface — this
//  screen renders sending → success (or the failure sheet) for the confirm lanes only.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

import Lottie

struct MigrationSendingView: View {
    private enum Constants {
        static let lottieNameLight = "sending"
        static let lottieNameDark = "sending-dark"
    }

    @Environment(\.colorScheme) private var colorScheme
    @PlatformBindable var store: StoreOf<MigrationSending>

    init(store: StoreOf<MigrationSending>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            content
                .navigationBarBackButtonHidden()
                .zashiSheet(isPresented: $store.isFailurePresented) {
                    MigrationBroadcastFailureSheetView(
                        failureKind: store.failureKind,
                        cancelTapped: { store.send(.cancelTapped) },
                        proceedWithoutTorTapped: { store.send(.proceedWithoutTorTapped) },
                        retryTapped: { store.send(.retryTapped) },
                        useSyncServerTapped: { store.send(.useSyncServerTapped) }
                    )
                    .alert($store.scope(state: \.alert, action: \.alert))
                }
        }
        .onAppear {
            store.send(.onAppear)
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .sending:
            sendingContent
                .screenHorizontalPadding()
                .applyScreenBackground()

        case .success:
            successContent
                .padding(.vertical, 1)
                .screenHorizontalPadding()
                .applySuccessScreenBackground()
        }
    }

    // MARK: - Sending

    @ViewBuilder private var sendingContent: some View {
        VStack(spacing: 0) {
            LottieView(
                animation:
                    .named(colorScheme == .light ? Constants.lottieNameLight : Constants.lottieNameDark)
            )
            .resizable()
            .looping()
            .frame(width: 170, height: 170)

            Text(localizable: .migrationSendingTitle)
                .zFont(.semiBold, size: 28, style: Design.Text.primary)
                .padding(.top, 16)

            Text(localizable: .migrationSendingSubtitleMigrated)
                .zFont(size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.center)
        }
    }

    // (The R8-T6 `waitingContent` countdown view was REMOVED 2026-08-07 with the `.waiting`
    // phase.)

    // MARK: - Success

    @ViewBuilder private var successContent: some View {
        VStack(spacing: 0) {
            Spacer()

            Asset.Assets.Illustrations.success1.image
                .resizable()
                .frame(width: 148, height: 148)

            Text(localizable: .migrationSendingSentTitle)
                .zFont(.semiBold, size: 28, style: Design.Text.primary)
                .padding(.top, 16)

            Text(store.sentSubtitle)
                .zFont(size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .padding(.top, 8)

            ZashiButton(
                String(localizable: .sendViewTransaction),
                type: .tertiary,
                infinityWidth: false
            ) {
                store.send(.viewTransactionTapped)
            }
            .padding(.top, 16)

            Spacer()

            ZashiButton(String(localizable: .generalClose)) {
                store.send(.closeTapped)
            }
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Previews

#Preview("Sending") {
    NavigationView {
        MigrationSendingView(
            store: StoreOf<MigrationSending>(
                initialState: MigrationSending.State(phase: .sending)
            ) {
                MigrationSending()
            }
        )
    }
}

#Preview("Success") {
    NavigationView {
        MigrationSendingView(
            store: StoreOf<MigrationSending>(
                initialState: MigrationSending.State(phase: .success, txId: "e87f1234567890abcdef6f28b")
            ) {
                MigrationSending()
            }
        )
    }
}

#Preview("Sending + failure sheet") {
    NavigationView {
        MigrationSendingView(
            store: StoreOf<MigrationSending>(
                initialState: MigrationSending.State(phase: .sending, isFailurePresented: true)
            ) {
                MigrationSending()
            }
        )
    }
}
