//
//  MigrationNoteSplitView.swift
//  zodl
//
//  Figma "Notes Splitting_Explainer_A" (confirm) → B3a (Splitting Funds…) → B3b (Split Confirmed!).
//  The user confirms on the explainer; the send-to-self then runs and the user waits ~15s for the
//  simulated confirmation before tapping Continue. The back control shows only on the explainer (the
//  broadcast is irreversible once started).
//

import ComposableArchitecture
import SwiftUI

struct MigrationNoteSplitView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<MigrationNoteSplit>
    let tokenName: String

    init(store: StoreOf<MigrationNoteSplit>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            Group {
                if store.step == .explainer {
                    explainerContent
                } else {
                    progressContent
                }
            }
            .navigationBarBackButtonHidden(store.step != .explainer)
            .onAppear { store.send(.onAppear) }
        }
        .applyScreenBackground()
    }

    // MARK: - Explainer (confirm before split)

    @ViewBuilder private var explainerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        MigrationPairedIcons()
                            .padding(.top, 4)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Split Your Wallet Funds")
                                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("This sends a transaction to yourself, breaking your balance into smaller notes. Each Ironwood migration transfer then settles independently — no waiting for change.")
                                .zFont(.regular, size: 14, style: Design.Text.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    detailsCard
                }
                .padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ZashiButton("Confirm") {
                store.send(.confirmTapped)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .screenHorizontalPadding()
    }

    // MARK: - Splitting / Confirmed (Figma B3a / B3b)

    @ViewBuilder private var progressContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    statusHeader

                    VStack(alignment: .leading, spacing: 8) {
                        Text(progressTitle)
                            .zFont(.semiBold, size: 28, style: Design.Text.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Splitting your balance into transfer-sized notes. This is a send-to-self — your \(tokenName) stays in Orchard.")
                            .zFont(.regular, size: 14, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    detailsCard
                }
                .padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .screenHorizontalPadding()
    }

    private var progressTitle: String {
        store.step == .confirmed ? "Split Confirmed!" : "Splitting Funds…"
    }

    @ViewBuilder private var statusHeader: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(
                        store.step == .confirmed
                            ? Design.Utility.SuccessGreen._500.color(colorScheme).opacity(0.15)
                            : Design.Surfaces.bgSecondary.color(colorScheme)
                    )
                    .frame(width: 64, height: 64)

                if store.step == .confirmed {
                    Image(systemName: "checkmark.seal.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .foregroundStyle(Design.Utility.SuccessGreen._500.color(colorScheme))
                } else {
                    ProgressView()
                        .scaleEffect(1.2)
                }
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    @ViewBuilder private var detailsCard: some View {
        VStack(spacing: 0) {
            if !store.txId.isEmpty {
                detailRow(title: "Transaction ID", value: store.txId)
                divider()
            }
            detailRow(title: "Amount", value: "\(store.totalAmount.decimalString()) \(tokenName)")
            divider()
            detailRow(title: "Fee", value: "\(store.fee.decimalString()) \(tokenName)")
        }
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 16) {
            if store.step == .splitting {
                progressInfoCard
                ZashiButton("Splitting Funds…") { }
                    .disabled(true)
            } else {
                ZashiButton("Continue") {
                    store.send(.continueTapped)
                }
            }
        }
        .padding(.bottom, 24)
    }

    @ViewBuilder private var progressInfoCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundStyle(Design.Text.tertiary.color(colorScheme))

            VStack(alignment: .leading, spacing: 4) {
                Text("Transaction in Progress")
                    .zFont(.semiBold, size: 14, style: Design.Text.primary)
                Text("Keep your phone on and the app open until this step completes.")
                    .zFont(.regular, size: 13, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    @ViewBuilder private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .zFont(.medium, size: 14, style: Design.Text.tertiary)

            Spacer(minLength: 16)

            Text(value)
                .zFont(.semiBold, size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder private func divider() -> some View {
        Rectangle()
            .fill(Design.Surfaces.strokeSecondary.color(colorScheme))
            .frame(height: 1)
    }
}
