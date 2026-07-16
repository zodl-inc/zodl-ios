//
//  MigrationSendingView.swift
//  zodl
//
//  "Sending" / "Sent" screen (MOB-1463, Figma S8 · sending 2618:6858 / sent 2618:6895). `onAppear`
//  drives the store's sequential transfer execution (MOB-1466). The `closeTapped` /
//  `viewTransactionTapped` delegates are emitted but consumed by nobody yet — chaining is the
//  coordinator's job (phase 3).
//
//  Also reused for the "Migrate anyway" dust lane (MOB-1487): when `store.usesMigratedCopy` is
//  true, the sending/sent subtitles swap to the migrated-copy strings; titles and buttons are
//  identical in both variants.
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
    @Perception.Bindable var store: StoreOf<MigrationSending>

    init(store: StoreOf<MigrationSending>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            content
                .navigationBarBackButtonHidden()
                .zashiSheet(isPresented: $store.isFailurePresented) {
                    failureSheetContent
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

            Text(localizable: store.usesMigratedCopy ? .migrationSendingSubtitleMigrated : .migrationSendingSubtitle)
                .zFont(size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.center)
        }
    }

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

            Text(localizable: store.usesMigratedCopy ? .migrationSendingSentSubtitleMigrated : .migrationSendingSentSubtitle)
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

    // MARK: - Failure sheet

    @ViewBuilder private var failureSheetContent: some View {
        VStack(spacing: 0) {
            Asset.Assets.Icons.alertOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)

            Text(localizable: .migrationNoteSplitFailedTitle)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Text(localizable: .migrationNoteSplitFailedBody)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)

            ZashiButton(String(localizable: .generalCancel), type: .secondary) {
                store.send(.cancelTapped)
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .migrationNoteSplitRetry)) {
                store.send(.retryTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
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
