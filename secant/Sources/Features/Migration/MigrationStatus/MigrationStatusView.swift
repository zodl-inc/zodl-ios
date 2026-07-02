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
                } else if store.isStalled {
                    resumeContent
                } else if store.presentation == .scheduledSuccess {
                    scheduledSuccessContent
                } else {
                    progressContent
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbar {
                // The live-progress screen is entered from the Home banner (a deep entry, no previous
                // screen), so its leading control is a close (X) that dismisses the whole flow back to
                // Home — not a back chevron. Success/complete use their Done button.
                if showsCloseButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            store.send(.doneTapped)
                        } label: {
                            Asset.Assets.Icons.xClose.image
                                .zImage(size: 24, style: Design.Text.primary)
                        }
                    }
                }
            }
            .onAppear { store.send(.onAppear) }
        }
    }

    private var showsCloseButton: Bool {
        !store.isComplete && store.presentation == .progress
    }

    // MARK: - Scheduled success (Figma B9)

    @ViewBuilder private var scheduledSuccessContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .center, spacing: 20) {
                    Spacer(minLength: 24)

                    Asset.Assets.Icons.checkVerifiedFilled.image
                        .zImage(size: 88, style: Design.Utility.SuccessGreen._500)

                    Text(localizable: .migrationStatusScheduledTitle)
                        .zFont(.semiBold, size: 28, style: Design.Text.primary)
                        .multilineTextAlignment(.center)

                    Text(localizable: .migrationStatusScheduledSubtitle(tokenName))
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

            ZashiButton(String(localizable: .generalDone)) {
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
            summaryRow(title: String(localizable: .migrationStatusSummaryTotalToTransfer), value: "\(store.orchardRemaining.decimalString()) \(tokenName)")
            divider()
            summaryRow(title: String(localizable: .migrationStatusSummaryPool), value: String(localizable: .migrationStatusSummaryPoolValue))
            divider()
            summaryRow(
                title: String(localizable: .migrationStatusSummaryTransfers),
                value: String(localizable: .migrationStatusSummaryTransfersValue(store.summary.transfersSent, store.summary.transfersTotal))
            )
            divider()
            summaryRow(
                title: String(localizable: .migrationStatusSummaryDuration),
                value: String(localizable: .migrationStatusSummaryDurationValue(store.summary.estimatedDurationHours))
            )
        }
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    // MARK: - Resume Migration (stalled — Figma B8 "Resume Migration")

    @ViewBuilder private var resumeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localizable: .migrationStatusResumeTitle)
                            .zFont(.semiBold, size: 28, style: Design.Text.primary)

                        Text(resumeSubtitle)
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

            VStack(spacing: 16) {
                windowMissedNote

                VStack(spacing: 12) {
                    ZashiButton(String(localizable: .migrationStatusSendNowButton)) {
                        store.send(.sendNowTapped)
                    }

                    ZashiButton(String(localizable: .migrationStatusRescheduleButton), type: .secondary) {
                        store.send(.rescheduleTapped)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .screenHorizontalPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .applyScreenBackground()
    }

    private var resumeSubtitle: String {
        let total = store.transfers.count
        let number = store.stalledTransferNumber
        let hoursAgo = store.transfers.first { $0.status == .overdue }.map { abs($0.hoursFromNow) } ?? 0
        if hoursAgo > 0 {
            return String(localizable: .migrationStatusResumeSubtitleAgo(number, total, hoursAgo))
        }
        return String(localizable: .migrationStatusResumeSubtitle(number, total))
    }

    @ViewBuilder private var windowMissedNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Text.tertiary)

            VStack(alignment: .leading, spacing: 4) {
                Text(localizable: .migrationStatusWindowMissedTitle)
                    .zFont(.semiBold, size: 14, style: Design.Text.primary)

                Text(localizable: .migrationStatusWindowMissedBody)
                    .zFont(.regular, size: 13, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Progress (Figma B8)

    @ViewBuilder private var progressContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localizable: .migrationStatusInProgressTitle)
                            .zFont(.semiBold, size: 28, style: Design.Text.primary)

                        Text(localizable: .migrationStatusInProgressSubtitle)
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

            // DEBUG/TESTING: broadcast the next transfer as soon as its send window allows,
            // without waiting for the background scheduler. Reuses the resume path's wiring
            // (`sendNowTapped` → coordinator → `executeNextPendingTransfer`), which only sends a
            // transfer that is actually due. TODO: [MOB-1455] remove before release.
            ZashiButton(String(localizable: .migrationStatusSendNowButton), type: .secondary) {
                store.send(.sendNowTapped)
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .generalDone)) {
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
                        Text(localizable: .migrationStatusTransferRowTitle(index + 1))
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
            Text(localizable: .migrationStatusProgressCardTitle)
                .zFont(.semiBold, size: 16, style: Design.Text.primary)

            ProgressView(value: Double(completed), total: Double(total))
                .tint(Design.Utility.SuccessGreen._500.color(colorScheme))

            Text(localizable: .migrationStatusProgressCardDetail(completed, total, percent))
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
        // Overdue is the actionable next step → dark numbered badge (matches the Resume Migration design).
        case .active, .overdue: return .active
        case .invalid, .expired: return .warning
        case .pending: return .pending
        }
    }

    private func statusLabel(_ row: MigrationTransferRow) -> String {
        switch row.status {
        case .sent: return String(localizable: .migrationStatusRowSent)
        case .active: return String(localizable: .migrationStatusRowReadyNow)
        case .overdue:
            let agoHours = abs(row.hoursFromNow)
            return agoHours > 0
                ? String(localizable: .migrationStatusRowOverdueAgo(agoHours))
                : String(localizable: .migrationStatusRowOverdue)
        case .pending:
            return row.hoursFromNow == 0
                ? String(localizable: .migrationStatusRowReadySoon)
                : String(localizable: .migrationStatusRowHours(row.hoursFromNow))
        case .invalid: return String(localizable: .migrationStatusRowInvalid)
        case .expired: return String(localizable: .migrationStatusRowExpired)
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
