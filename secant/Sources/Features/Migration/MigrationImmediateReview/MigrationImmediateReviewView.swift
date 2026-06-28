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
                        Text("Review Transfer")
                            .zFont(.semiBold, size: 28, style: Design.Text.primary)

                        Text("Your full Orchard balance will be transferred to Ironwood in a single on-chain transfer.")
                            .zFont(.regular, size: 14, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your Transfer")
                                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                            Text("Once confirmed, this transfer cannot be cancelled.")
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

            ZashiButton("Confirm") {
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
                Text("Transfer 1 of 1")
                    .zFont(.medium, size: 16, style: Design.Text.primary)
                Text("Send immediately")
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
                Text("Privacy Disclaimer")
                    .zFont(.semiBold, size: 14, style: Design.Text.primary)
                    .foregroundColor(.orange)
                Text("Your full balance will be revealed — crossing the pool boundary reveals the transaction amount. We recommend going back and selecting Migrate with Privacy instead.")
                    .zFont(.regular, size: 13, style: Design.Text.tertiary)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: "info.circle")
                .foregroundStyle(.orange)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Color.orange.opacity(0.12))
        }
    }

    // MARK: - Sending

    @ViewBuilder private var sendingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Sending…")
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .applyScreenBackground()
    }

    // MARK: - Failed

    @ViewBuilder private var failedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(.orange)
                .padding(.top, 24)

            Text("Transfer failed")
                .zFont(.semiBold, size: 28, style: Design.Text.primary)

            Text("Something went wrong. Please try again from the migration screen.")
                .zFont(.regular, size: 16, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            ZashiButton("Close", type: .secondary) {
                store.send(.doneTapped)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .screenHorizontalPadding()
        .applyScreenBackground()
    }
}
