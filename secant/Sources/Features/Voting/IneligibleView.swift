import SwiftUI
import ComposableArchitecture

struct IneligibleView: View {
    @Environment(\.colorScheme)
    var colorScheme

    let store: StoreOf<Voting>

    var body: some View {
        WithPerceptionTracking {
            VotingBlockingBackdrop(store: store)
                .votingBlockingSheet(
                    isActive: { store.currentScreen == .ineligible },
                    onExit: { store.send(.backToRoundsList) }
                ) { dismiss in
                    sheetContent(dismiss: dismiss)
                }
        }
    }

    // MARK: - Sheet

    @ViewBuilder
    private func sheetContent(dismiss: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            sheetIcon()
                .padding(.top, 16)
                .padding(.bottom, 16)

            Text(localizable: .coinVoteIneligibleTitle)
                .zFont(.semiBold, size: 22, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)

            explanationCard()
                .padding(.bottom, 12)

            infoCard()
                .padding(.bottom, 24)

            ZashiButton(String(localizable: .coinVoteCommonClose)) {
                dismiss()
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func sheetIcon() -> some View {
        ZStack {
            Circle()
                .fill(Design.Utility.WarningYellow._500.color(colorScheme).opacity(0.1))
                .frame(width: 48, height: 48)
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Design.Utility.WarningYellow._500.color(colorScheme).opacity(0.8))
        }
    }

    // MARK: - Explanation Card

    @ViewBuilder
    private func explanationCard() -> some View {
        let reason = store.ineligibilityReason ?? .noNotes

        VStack(alignment: .leading, spacing: 12) {
            switch reason {
            case .noNotes:
                Text(localizable: .coinVoteIneligibleNoNotesMessage(snapshotHeightFormatted))
                    .zFont(.regular, size: 15, style: Design.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .balanceTooLow:
                Text(localizable: .coinVoteIneligibleBalanceTooLowMessage(balanceFormatted))
                    .zFont(.regular, size: 15, style: Design.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            detailRow(
                label: String(localizable: .coinVoteIneligibleDetailSnapshot),
                value: String(localizable: .coinVoteCommonBlockNumber(snapshotHeightFormatted))
            )

            switch reason {
            case .noNotes:
                detailRow(label: String(localizable: .coinVoteIneligibleDetailNotesFound), value: "0")
            case .balanceTooLow:
                detailRow(
                    label: String(localizable: .coinVoteIneligibleDetailYourBalance),
                    value: String(localizable: .coinVoteCommonZecValue(balanceFormatted))
                )
                detailRow(
                    label: String(localizable: .coinVoteIneligibleDetailMinimum),
                    value: String(localizable: .coinVoteIneligibleDetailMinimumValue)
                )
                detailRow(label: String(localizable: .coinVoteIneligibleDetailBallots), value: "0")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Design.Surfaces.bgPrimary.color(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Design.Surfaces.strokeSecondary.color(colorScheme), lineWidth: 1)
        )
    }

    // MARK: - Info Card

    @ViewBuilder
    private func infoCard() -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(Design.Text.tertiary.color(colorScheme))

            Text(localizable: .coinVoteIneligibleInfo)
                .zFont(.regular, size: 14, style: Design.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Design.Text.secondary.color(colorScheme).opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .zFont(.medium, size: 14, style: Design.Text.tertiary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(Design.Text.primary.color(colorScheme))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var snapshotHeightFormatted: String {
        let height = store.activeSession?.snapshotHeight ?? 0
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: height)) ?? "\(height)"
    }

    private var balanceFormatted: String {
        let zec = Double(store.votingWeight) / 100_000_000.0
        return String(format: "%.3f", zec)
    }
}
