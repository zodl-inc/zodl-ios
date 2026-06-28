//
//  MigrationImmediateReviewView.swift
//  zodl
//
//  Review Transfer → Sending → Migration Complete (immediate path). Figma A2 (2539:63339) for review;
//  the finished state reuses the shared MigrationCompleteView (Figma C6).
//

import ComposableArchitecture
import SwiftUI

struct MigrationImmediateReviewView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<MigrationImmediateReview>
    let tokenName: String

    init(store: StoreOf<MigrationImmediateReview>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            Group {
                switch store.step {
                case .review:
                    reviewContent
                case .sending:
                    sendingContent
                case .sent:
                    MigrationCompleteView(
                        transferred: store.amount,
                        dust: .zero,
                        transfersSent: 1,
                        transfersTotal: 1,
                        durationHours: 0,
                        tokenName: tokenName
                    ) {
                        store.send(.doneTapped)
                    }
                case .failed:
                    failedContent
                }
            }
            .navigationBarBackButtonHidden(store.step != .review)
            .onAppear { store.send(.onAppear) }
        }
    }

    // MARK: - Review (Figma A2)

    @ViewBuilder private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localizable: .migrationImmediateReviewTitle)
                            .zFont(.semiBold, size: 28, style: Design.Text.primary)

                        Text(localizable: .migrationImmediateReviewSubtitle)
                            .zFont(.regular, size: 14, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(localizable: .migrationImmediateReviewYourTransfer)
                                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                            Text(localizable: .migrationImmediateReviewCannotCancel)
                                .zFont(.regular, size: 13, style: Design.Text.tertiary)
                        }

                        transferRow
                    }
                }
                .padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            privacyDisclaimer
                .padding(.bottom, 16)

            ZashiButton(String(localizable: .generalConfirm)) {
                store.send(.confirmTapped)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .screenHorizontalPadding()
        .applyScreenBackground()
    }

    @ViewBuilder private var transferRow: some View {
        HStack(alignment: .center, spacing: 12) {
            MigrationStepBadge(number: 1, style: .active)

            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .migrationImmediateReviewTransferOneOfOne)
                    .zFont(.medium, size: 16, style: Design.Text.primary)
                Text(localizable: .migrationImmediateReviewSendImmediately)
                    .zFont(.regular, size: 13, style: Design.Text.tertiary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(store.amount.decimalString()) \(tokenName)")
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)
                Text(MigrationFiat.string(for: store.amount))
                    .zFont(.regular, size: 13, style: Design.Text.tertiary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    @ViewBuilder private var privacyDisclaimer: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(localizable: .migrationImmediateReviewPrivacyDisclaimerTitle)
                    .zFont(.semiBold, size: 14, style: Design.Text.primary)
                    .foregroundColor(Design.Utility.WarningYellow._500.color(colorScheme))
                Text(localizable: .migrationImmediateReviewPrivacyDisclaimerBody)
                    .zFont(.regular, size: 13, style: Design.Text.tertiary)
                    .foregroundColor(Design.Utility.WarningYellow._500.color(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Asset.Assets.infoOutline.image
                .zImage(size: 20, color: Design.Utility.WarningYellow._500.color(colorScheme))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Utility.WarningYellow._500.color(colorScheme).opacity(0.12))
        }
    }

    // MARK: - Sending

    @ViewBuilder private var sendingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text(localizable: .migrationImmediateReviewSending)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .applyScreenBackground()
    }

    // MARK: - Failed

    @ViewBuilder private var failedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Asset.Assets.Icons.alertTriangle.image
                .zImage(size: 56, color: Design.Utility.WarningYellow._500.color(colorScheme))
                .padding(.top, 24)

            Text(localizable: .migrationImmediateReviewFailedTitle)
                .zFont(.semiBold, size: 28, style: Design.Text.primary)

            Text(localizable: .migrationImmediateReviewFailedBody)
                .zFont(.regular, size: 16, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            ZashiButton(String(localizable: .generalClose), type: .secondary) {
                store.send(.doneTapped)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .screenHorizontalPadding()
        .applyScreenBackground()
    }
}
