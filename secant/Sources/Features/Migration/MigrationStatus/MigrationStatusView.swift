//
//  MigrationStatusView.swift
//  zodl
//
//  Post-commit status:
//  - scheduledSuccess: "Migration Scheduled" (Figma B9).
//  - progress: live per-transfer list + progress bar (Figma B8). Reached from the Home banner, so its
//    leading control dismisses the whole flow back to Home.
//  - complete: shared "Migration Complete" summary (Figma C6).
//

import ComposableArchitecture
import SwiftUI

struct MigrationStatusView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<MigrationStatus>
    let tokenName: String

    init(store: StoreOf<MigrationStatus>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            Group {
                if store.isComplete {
                    MigrationCompleteView(
                        transferred: store.summary.transferred,
                        dust: store.summary.dust,
                        transfersSent: store.summary.transfersSent,
                        transfersTotal: store.summary.transfersTotal,
                        durationHours: store.summary.estimatedDurationHours,
                        tokenName: tokenName
                    ) {
                        store.send(.doneTapped)
                    }
                } else if store.presentation == .scheduledSuccess {
                    scheduledSuccessContent
                } else {
                    progressContent
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbar {
                // Only the live-progress screen (entered from the Home banner) gets a back control —
                // it closes the whole flow back to Home. Success/complete use their Done button.
                if showsBackButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            store.send(.doneTapped)
                        } label: {
                            Image(systemName: "chevron.backward")
                                .foregroundStyle(Design.Text.primary.color(colorScheme))
                        }
                    }
                }
            }
            .onAppear { store.send(.onAppear) }
        }
    }

    private var showsBackButton: Bool {
        !store.isComplete && store.presentation == .progress
    }

    // MARK: - Scheduled success (Figma B9)

    @ViewBuilder private var scheduledSuccessContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .center, spacing: 20) {
                    Spacer(minLength: 24)

                    Image(systemName: "checkmark.seal.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .foregroundStyle(Design.Utility.SuccessGreen._500.color(colorScheme))

                    Text("Migration Scheduled")
                        .zFont(.semiBold, size: 28, style: Design.Text.primary)
                        .multilineTextAlignment(.center)

                    Text("Your \(tokenName) will be migrated to the Ironwood pool based on the schedule you approved.")
                        .zFont(.regular, size: 16, style: Design.Text.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    scheduledSummaryCard
                        .padding(.top, 12)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }

            ZashiButton("Done") {
                store.send(.doneTapped)
            }
            .padding(.bottom, 24)
        }
        .screenHorizontalPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .applyScreenBackground()
    }

    @ViewBuilder private var scheduledSummaryCard: some View {
        VStack(spacing: 0) {
            summaryRow(title: "Total to transfer", value: "\(store.orchardRemaining.decimalString()) \(tokenName)")
            divider()
            summaryRow(title: "Pool", value: "Orchard → Ironwood")
            divider()
            summaryRow(title: "Transfers", value: "\(store.summary.transfersSent) of \(store.summary.transfersTotal)")
            divider()
            summaryRow(title: "Duration", value: "~\(store.summary.estimatedDurationHours) hours")
        }
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    // MARK: - Progress (Figma B8)

    @ViewBuilder private var progressContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Migration in Progress")
                            .zFont(.semiBold, size: 28, style: Design.Text.primary)

                        Text("Transfers send automatically in the background. Keep ZODL installed.")
                            .zFont(.regular, size: 14, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    transfersList

                    progressCard
                }
                .padding(.top, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ZashiButton("Done") {
                store.send(.doneTapped)
            }
            .padding(.bottom, 24)
        }
        .screenHorizontalPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .applyScreenBackground()
    }

    @ViewBuilder private var transfersList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.transfers.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 4) {
                        MigrationStepBadge(number: index + 1, style: badgeStyle(row.status))
                        if index < store.transfers.count - 1 {
                            Rectangle()
                                .fill(Design.Surfaces.strokeSecondary.color(colorScheme))
                                .frame(width: 1.5, height: 24)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transfer \(index + 1)")
                            .zFont(.medium, size: 16, style: Design.Text.primary)
                        Text(statusLabel(row))
                            .zFont(.regular, size: 13, style: Design.Text.tertiary)
                    }
                    .padding(.top, 2)

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(row.amount.decimalString()) \(tokenName)")
                            .zFont(.semiBold, size: 16, style: Design.Text.primary)
                        Text(MigrationFiat.string(for: row.amount))
                            .zFont(.regular, size: 13, style: Design.Text.tertiary)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder private var progressCard: some View {
        let completed = store.progress?.completedTransfers ?? store.summary.transfersSent
        let total = max(store.progress?.totalTransfers ?? store.summary.transfersTotal, 1)
        let percent = Int((Double(completed) / Double(total) * 100).rounded())

        VStack(alignment: .leading, spacing: 12) {
            Text("Migration Progress")
                .zFont(.semiBold, size: 16, style: Design.Text.primary)

            ProgressView(value: Double(completed), total: Double(total))
                .tint(Design.Utility.SuccessGreen._500.color(colorScheme))

            Text("\(completed) of \(total) transfers complete · \(percent)% complete")
                .zFont(.regular, size: 13, style: Design.Text.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    // MARK: - Helpers

    private func badgeStyle(_ status: MigrationTransferRow.Status) -> MigrationStepBadge.Style {
        switch status {
        case .sent: return .sent
        case .active: return .active
        case .overdue, .invalid, .expired: return .warning
        case .pending: return .pending
        }
    }

    private func statusLabel(_ row: MigrationTransferRow) -> String {
        switch row.status {
        case .sent: return "Sent"
        case .active: return "Ready now"
        case .overdue: return "Overdue"
        case .pending: return row.hoursFromNow == 0 ? "Ready soon" : "~\(row.hoursFromNow) hours"
        case .invalid: return "Invalid"
        case .expired: return "Expired"
        }
    }

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
