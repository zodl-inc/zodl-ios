//
//  OrchardMigrationView.swift
//  ZODL
//
// TODO: [#MOB-IRONWOOD] Replace placeholder UI with finalised designs from build 3.7.1(4).
// All string literals below should be moved to Localizable.xcstrings before shipping.
//

import ComposableArchitecture
import SwiftUI
@preconcurrency import ZcashLightClientKit

struct OrchardMigrationView: View {
    @Bindable var store: StoreOf<OrchardMigration>

    var body: some View {
        Group {
            switch store.phase {
            case .unknown:
                ProgressView()

            case .notStarted:
                EmptyView()

            case .awaitingNoteSplitConfirm(let proposal):
                NoteSplitConfirmView(proposal: proposal, torEnabled: $store.torEnabled.sending(\.torToggled)) {
                    store.send(.noteSplitConfirmTapped(proposal))
                }

            case .awaitingSplitConfirmation:
                MigrationWaitingView(
                    title: "Preparing your funds",
                    detail: "Splitting notes for privacy — waiting for on-chain confirmation."
                )

            case .proposalReview(let schedule):
                MigrationScheduleReviewView(schedule: schedule, torEnabled: $store.torEnabled.sending(\.torToggled)) {
                    store.send(.scheduleConfirmTapped(schedule))
                }

            case .inProgress(let progress):
                MigrationProgressView(progress: progress, torEnabled: $store.torEnabled.sending(\.torToggled)) {
                    store.send(.executeNextTransferTapped)
                }

            case .requiresAttention(let reason):
                MigrationAttentionView(reason: reason) {
                    store.send(.restartTapped)
                }

            case .complete:
                MigrationCompleteView {
                    store.send(.completionAcknowledgeTapped)
                }

            case .failed(let error):
                MigrationErrorView(error: error) {
                    store.send(.restartTapped)
                }
            }
        }
        .onAppear { store.send(.onAppear) }
        .onDisappear { store.send(.onDisappear) }
    }
}

// MARK: - Sub-views

private struct NoteSplitConfirmView: View {
    let proposal: MigrationProcessorClient.NoteSplitProposalModel
    @Binding var torEnabled: Bool
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("Prepare your Orchard funds")
                .font(.title2.bold())
            Text("Before migrating, your funds need to be split into smaller amounts for privacy. This requires one on-chain transaction.")
                .multilineTextAlignment(.center)
            TorToggleRow(enabled: $torEnabled)
            // TODO: [#MOB-IRONWOOD] Show fee from proposal.feeSatoshi
            Button("Prepare funds", action: onConfirm)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct MigrationScheduleReviewView: View {
    let schedule: MigrationProcessorClient.MigrationScheduleModel
    @Binding var torEnabled: Bool
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("Review migration plan")
                .font(.title2.bold())
            Text("Your funds will be moved in \(schedule.transfers.count) transfers over approximately \(schedule.estimatedDurationHours) hours. Open ZODL each day to continue.")
                .multilineTextAlignment(.center)
            TorToggleRow(enabled: $torEnabled)
            // TODO: [#MOB-IRONWOOD] Show per-transfer amount list from schedule.transfers
            Button("Start migration", action: onConfirm)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct MigrationProgressView: View {
    let progress: MigrationProcessorClient.MigrationProgressModel
    @Binding var torEnabled: Bool
    let onSendNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("Migration in progress")
                .font(.title2.bold())
            ProgressView(
                value: Double(progress.completedTransfers),
                total: Double(progress.totalTransfers)
            )
            Text("\(progress.completedTransfers) of \(progress.totalTransfers) transfers complete")
                .font(.caption)
            if let nextHeight = progress.nextTransferReadyAtHeight {
                Text("Next transfer available around block \(nextHeight)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TorToggleRow(enabled: $torEnabled)
                Button("Send next transfer", action: onSendNext)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

private struct MigrationWaitingView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }
}

private struct MigrationAttentionView: View {
    let reason: MigrationProcessorClient.AttentionReason
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(reasonTitle).font(.headline)
            Text(reasonDetail).multilineTextAlignment(.center).font(.subheadline)
            Button("Try again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var reasonTitle: String {
        switch reason {
        case .invalidTransfer: "Transfer already sent"
        case .transferExpired: "Transfer expired"
        case .syncRequired: "Sync required"
        }
    }

    private var reasonDetail: String {
        switch reason {
        case .invalidTransfer:
            "This transfer was already sent, possibly from another device. Open ZODL on your primary device to continue."
        case .transferExpired:
            "A scheduled transfer expired before it could be sent. ZODL will prepare a new one."
        case .syncRequired:
            "ZODL needs to sync with the network before sending the next transfer. Please stay connected and try again."
        }
    }
}

private struct MigrationCompleteView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Migration complete")
                .font(.title2.bold())
            Text("All your funds have been moved to the Ironwood pool.")
                .multilineTextAlignment(.center)
            Button("Done", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct MigrationErrorView: View {
    let error: ZcashError
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("Migration error")
                .font(.headline)
            Text(error.detailedMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct TorToggleRow: View {
    @Binding var enabled: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use Tor")
                    .font(.subheadline.weight(.medium))
                Text("Recommended — hides your IP during migration")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $enabled).labelsHidden()
        }
        .padding(.horizontal)
    }
}
