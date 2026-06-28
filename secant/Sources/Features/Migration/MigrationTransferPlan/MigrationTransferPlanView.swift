//
//  MigrationTransferPlanView.swift
//  zodl
//
//  "Transfer Plan" — one-time review of the full migration schedule before signing (Figma B4,
//  2630:11510). The private path splits the balance into 5–8 randomly-sized transfers.
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
                            summarySection(schedule)
                            transfersSection(schedule)
                        }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Summary

    @ViewBuilder private func summarySection(_ schedule: MigrationSchedule) -> some View {
        VStack(spacing: 0) {
            summaryRow(title: "Destination", value: "Ironwood")
            divider()
            summaryRow(
                title: "Summary",
                value: "\(schedule.transfers.count) transfers · ~\(schedule.estimatedDurationHours) hours"
            )
        }
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    // MARK: - Transfers list

    @ViewBuilder private func transfersSection(_ schedule: MigrationSchedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your balance will be split into")
                .zFont(.semiBold, size: 16, style: Design.Text.primary)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(schedule.transfers.enumerated()), id: \.element.id) { index, transfer in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 4) {
                            MigrationStepBadge(number: index + 1, style: index == 0 ? .active : .pending)
                            if index < schedule.transfers.count - 1 {
                                Rectangle()
                                    .fill(Design.Surfaces.strokeSecondary.color(colorScheme))
                                    .frame(width: 1.5, height: 28)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transfer \(index + 1)")
                                .zFont(.medium, size: 16, style: Design.Text.primary)
                            Text(timeLabel(for: index))
                                .zFont(.regular, size: 13, style: Design.Text.tertiary)
                        }
                        .padding(.top, 2)

                        Spacer(minLength: 8)

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(transfer.amount.decimalString()) \(tokenName)")
                                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                            Text(MigrationFiat.string(for: transfer.amount))
                                .zFont(.regular, size: 13, style: Design.Text.tertiary)
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    private func timeLabel(for index: Int) -> String {
        index == 0 ? "Ready now" : "~\(index * 6) hours"
    }

    // MARK: - Helpers

    @ViewBuilder private func summaryRow(title: String, value: String) -> some View {
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

    @ViewBuilder private func divider() -> some View {
        Rectangle()
            .fill(Design.Surfaces.strokeSecondary.color(colorScheme))
            .frame(height: 1)
    }
}
