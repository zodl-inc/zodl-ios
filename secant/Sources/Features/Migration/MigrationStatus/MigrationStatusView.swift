//
//  MigrationStatusView.swift
//  zodl
//
//  "Migration Scheduled" success + ongoing progress + complete / dust.
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
            VStack(alignment: .leading, spacing: 0) {
                switch store.presentation {
                case .scheduledSuccess:
                    scheduledSuccessContent

                case .progress:
                    progressContent
                }

                Spacer(minLength: 24)

                ZashiButton("Done") {
                    store.send(.doneTapped)
                }
            }
            .screenHorizontalPadding()
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { store.send(.onAppear) }
        }
        .applyScreenBackground()
    }

    // MARK: - Scheduled success

    @ViewBuilder private var scheduledSuccessContent: some View {
        VStack(alignment: .center, spacing: 20) {
            Spacer(minLength: 40)

            Image(systemName: "checkmark.seal.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .foregroundStyle(Design.Utility.SuccessGreen._500.color(colorScheme))

            Text("Migration Scheduled")
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .multilineTextAlignment(.center)

            Text("Your ZEC will be migrated to the Ironwood pool based on the schedule you approved.")
                .zFont(size: 16, style: Design.Text.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Progress

    @ViewBuilder private var progressContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(progressTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .fixedSize(horizontal: false, vertical: true)

            if isComplete, store.orchardRemaining.amount > 0 {
                Text("A negligible amount remains in Orchard — no action needed.")
                    .zFont(size: 16, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let progress = store.progress {
                VStack(alignment: .leading, spacing: 16) {
                    ProgressView(
                        value: Double(progress.completedTransfers),
                        total: Double(max(progress.totalTransfers, 1))
                    )
                    .tint(Design.Utility.SuccessGreen._500.color(colorScheme))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(progress.completedTransfers) of \(progress.totalTransfers) transfers complete")
                            .zFont(.medium, size: 16, style: Design.Text.primary)

                        Text("\(progress.remainingOrchard.decimalString()) \(tokenName) remaining in Orchard")
                            .zFont(size: 14, style: Design.Text.tertiary)
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    // MARK: - Helpers

    private var isComplete: Bool {
        store.migrationState == .complete
    }

    private var progressTitle: String {
        if isComplete {
            return "Migration Complete"
        }
        return "Migration in Progress"
    }
}
