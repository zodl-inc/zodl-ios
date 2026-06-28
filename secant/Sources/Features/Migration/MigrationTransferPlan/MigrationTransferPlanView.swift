//
//  MigrationTransferPlanView.swift
//  zodl
//
//  "Transfer Plan" — one-time review of the full migration schedule before signing.
//

import ComposableArchitecture
import SwiftUI

struct MigrationTransferPlanView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<MigrationTransferPlan>
    let tokenName: String

    init(store: StoreOf<MigrationTransferPlan>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Transfer Plan")
                                .zFont(.semiBold, size: 28, style: Design.Text.primary)

                            Text(bodyText)
                                .zFont(.regular, size: 14, style: Design.Text.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if store.isLoading {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .padding(.vertical, 48)
                                Spacer()
                            }
                        } else if let schedule = store.schedule {
                            transfersSection(schedule)
                            summarySection(schedule)
                        }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                }

                ZashiButton("Confirm") {
                    store.send(.confirmTapped)
                }
                .disabled(store.isCommitting || store.schedule == nil)
                .padding(.bottom, 20)
            }
            .screenHorizontalPadding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { store.send(.onAppear) }
        }
        .applyScreenBackground()
    }

    private var bodyText: String {
        let count = store.schedule?.transfers.count ?? 0
        let hours = store.schedule?.estimatedDurationHours ?? 0
        return "Your balance splits into \(count) transfers over ~\(hours) hours. "
            + "Approve once and ZODL handles the rest — just keep the app installed. "
            + "Amounts are randomized for privacy."
    }

    @ViewBuilder
    private func transfersSection(_ schedule: MigrationSchedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Migration Progress")
                .zFont(.semiBold, size: 18, style: Design.Text.primary)

            VStack(spacing: 0) {
                ForEach(Array(schedule.transfers.enumerated()), id: \.element.id) { index, transfer in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transfer \(index + 1)")
                                .zFont(.medium, size: 16, style: Design.Text.primary)

                            Text(index == 0 ? "Ready now" : "~\(index * 6)h")
                                .zFont(.regular, size: 13, style: Design.Text.tertiary)
                        }

                        Spacer(minLength: 8)

                        Text("\(transfer.amount.decimalString()) \(tokenName)")
                            .zFont(.semiBold, size: 16, style: Design.Text.primary)
                    }
                    .padding(.vertical, 12)

                    if index < schedule.transfers.count - 1 {
                        Divider()
                            .overlay(Design.Surfaces.strokeSecondary.color(colorScheme))
                    }
                }
            }
            .padding(.horizontal, 16)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._xl)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ schedule: MigrationSchedule) -> some View {
        let totalZatoshi = schedule.transfers.reduce(Int64(0)) { $0 + $1.amount.amount }

        VStack(spacing: 0) {
            summaryRow(title: "Total to migrate", value: "\(zecString(fromZatoshi: totalZatoshi)) \(tokenName)")
            Divider().overlay(Design.Surfaces.strokeSecondary.color(colorScheme))
            summaryRow(title: "Pool", value: "Orchard → Ironwood")
            Divider().overlay(Design.Surfaces.strokeSecondary.color(colorScheme))
            summaryRow(title: "Transfers", value: "\(schedule.transfers.count)")
            Divider().overlay(Design.Surfaces.strokeSecondary.color(colorScheme))
            summaryRow(title: "Duration", value: "~\(schedule.estimatedDurationHours) hours")
        }
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    @ViewBuilder
    private func summaryRow(title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .zFont(.regular, size: 14, style: Design.Text.tertiary)

            Spacer(minLength: 8)

            Text(value)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 14)
    }

    /// Formats a raw zatoshi total as a ZEC string (up to 8 fraction digits), mirroring
    /// `Zatoshi.decimalString()`. Computed inline because the store does not expose a total and
    /// `Zatoshi` arithmetic is not visible without importing the SDK.
    private func zecString(fromZatoshi zatoshi: Int64) -> String {
        let zec = Decimal(zatoshi) / Decimal(100_000_000)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        formatter.roundingMode = .halfEven
        return formatter.string(from: zec as NSDecimalNumber) ?? "\(zec)"
    }
}
