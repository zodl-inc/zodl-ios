//
//  MigrationImmediateReviewView.swift
//  zodl
//
//  Review Transfer → Sending → Sent (immediate path). Figma section 2617:7260.
//

import ComposableArchitecture
import SwiftUI

struct MigrationImmediateReviewView: View {
    @Perception.Bindable var store: StoreOf<MigrationImmediateReview>
    let tokenName: String

    init(store: StoreOf<MigrationImmediateReview>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 16) {
                switch store.step {
                case .review:
                    reviewContent()
                case .sending:
                    sendingContent()
                case .sent:
                    sentContent()
                case .failed:
                    failedContent()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 24)
            .screenHorizontalPadding()
            .onAppear { store.send(.onAppear) }
        }
        .applyScreenBackground()
    }

    @ViewBuilder private func reviewContent() -> some View {
        Text("Review Transfer")
            .zFont(.bold, size: 28, style: Design.Text.primary)
            .padding(.bottom, 8)

        VStack(spacing: 0) {
            detailRow("Amount", value: "\(store.amount.decimalString()) \(tokenName)")
            detailRow("To", value: "Ironwood pool")
            detailRow("Type", value: "Single transfer")
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(.light))
        }

        Spacer()

        ZashiButton("Confirm") {
            store.send(.confirmTapped)
        }
        .padding(.bottom, 24)
    }

    @ViewBuilder private func sendingContent() -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Sending…")
                .zFont(.bold, size: 20, style: Design.Text.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder private func sentContent() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .frame(width: 64, height: 64)
                .foregroundStyle(.green)
                .padding(.top, 24)

            Text("Sent!")
                .zFont(.bold, size: 28, style: Design.Text.primary)

            Text("Your ZEC has moved to the Ironwood pool.")
                .zFont(.regular, size: 16, style: Design.Text.tertiary)

            if !store.txId.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transaction ID")
                        .zFont(.medium, size: 14, style: Design.Text.support)
                    Text(store.txId)
                        .zFont(.regular, size: 12, style: Design.Text.tertiary)
                }
                .padding(.top, 8)
            }

            Spacer()

            ZashiButton("Close") {
                store.send(.doneTapped)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func failedContent() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .resizable()
                .frame(width: 64, height: 64)
                .foregroundStyle(.orange)
                .padding(.top, 24)

            Text("Transfer failed")
                .zFont(.bold, size: 28, style: Design.Text.primary)

            Text("Something went wrong. Please try again from the migration screen.")
                .zFont(.regular, size: 16, style: Design.Text.tertiary)

            Spacer()

            ZashiButton("Close", type: .secondary) {
                store.send(.doneTapped)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .zFont(.medium, size: 16, style: Design.Text.tertiary)
            Spacer()
            Text(value)
                .zFont(.semiBold, size: 16, style: Design.Text.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
