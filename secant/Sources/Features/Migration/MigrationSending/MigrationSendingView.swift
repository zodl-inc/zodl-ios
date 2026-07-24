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
//  MOB-1497 (T8, Q3'26 canvas): per-lane copy switching is back for exactly one string — the
//  success subtitle now reads `store.sentSubtitle` (`MigrationSending.State`'s own selection
//  between the "sent"/"migrated" wording, keyed off `isManualStepLane`) instead of the hardcoded
//  `migrationSendingSentSubtitleMigrated` key. The title stays the unconditional "Sent!"
//  (`migrationSendingSentTitle`) in every lane.
//
//  R8-T6: a third phase, `.waiting(target:)`, appears only on the Status screen's "Send now" lane
//  (`entersViaSendNow`) — the app-side privacy gate wasn't clear yet, so sync is held stopped and
//  the screen counts down to `target` instead of showing the sending animation. A live countdown
//  (`Text(timerInterval:)`, native SwiftUI — no store-side ticking) plus a Cancel affordance that
//  resumes sync without sending anything.
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

        case .waiting(let target):
            waitingContent(target: target)
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

    // MARK: - Waiting (R8-T6)

    /// Reuses `sendingContent`'s layout shape (same Lottie, title-then-subtitle) with the
    /// silence-window copy, a live countdown, and a Cancel affordance. `Text(timerInterval:)` is
    /// native SwiftUI — it live-updates on its own, so no store-side per-second ticking is needed;
    /// the store only needs to know WHEN to fire (`MigrationSending`'s clock-driven wait effect).
    @ViewBuilder private func waitingContent(target: Date) -> some View {
        VStack(spacing: 0) {
            LottieView(
                animation:
                    .named(colorScheme == .light ? Constants.lottieNameLight : Constants.lottieNameDark)
            )
            .resizable()
            .looping()
            .frame(width: 170, height: 170)

            Text(localizable: .migrationSendingWaitingTitle)
                .zFont(.semiBold, size: 28, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)

            Text(localizable: .migrationSendingWaitingBody)
                .zFont(size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.center)

            // R8-T6 fix-wave (Minor-2, folded): `now` bound ONCE and reused for both bounds —
            // reading `Date()` a second time for the range's upper bound (the original shape) is a
            // TOCTOU: if `target` fell in the gap between the two reads, `now...target` would have
            // `lowerBound > upperBound` and trap. `now...max(now, target)` is always a valid range;
            // a stale/past `target` just renders 0:00 — `.waitFired`'s own fresh gate re-check
            // (fired immediately when `remaining <= 0`) remains the sole authority on what happens
            // next, so a momentary 0:00 here is harmless.
            let now = Date()
            Text(timerInterval: now...max(now, target), countsDown: true)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .monospacedDigit()
                .padding(.top, 16)

            ZashiButton(String(localizable: .generalCancel), type: .secondary) {
                store.send(.waitCancelTapped)
            }
            .padding(.top, 24)
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

#Preview("Waiting (R8-T6)") {
    NavigationView {
        MigrationSendingView(
            store: StoreOf<MigrationSending>(
                initialState: MigrationSending.State(
                    phase: .waiting(target: Date().addingTimeInterval(582)),
                    entersViaSendNow: true
                )
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
