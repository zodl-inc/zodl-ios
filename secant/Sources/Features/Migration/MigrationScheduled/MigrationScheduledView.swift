//
//  MigrationScheduledView.swift
//  zodl
//
//  "Migration Scheduled" screen (MOB-1463, Figma S9 · 2630:11282). Visually complete per Figma;
//  all summary fields are placeholders — wiring the real data lands in MOB-1466. The `doneTapped`
//  delegate is emitted but consumed by nobody yet.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationScheduledView: View {
    @Perception.Bindable var store: StoreOf<MigrationScheduled>

    init(store: StoreOf<MigrationScheduled>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Spacer()

                Asset.Assets.Illustrations.success1.image
                    .resizable()
                    .frame(width: 148, height: 148)

                Text(localizable: .migrationScheduledTitle)
                    .zFont(.semiBold, size: 28, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)

                Text(localizable: .migrationScheduledSubtitle)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                summaryCard
                    .padding(.top, 24)

                Spacer()

                ZashiButton(String(localizable: .generalDone)) {
                    store.send(.doneTapped)
                }
                .padding(.bottom, 24)
            }
            .padding(.vertical, 1)
            .screenHorizontalPadding()
            .navigationBarBackButtonHidden()
        }
        .applySuccessScreenBackground()
    }

    // MARK: - Summary card

    @ViewBuilder private var summaryCard: some View {
        VStack(spacing: 0) {
            MigrationDetailRow(
                title: String(localizable: .migrationScheduledRowTotal),
                value: "\(store.totalAmount.decimalString()) ZEC",
                rowAppereance: .top,
                isContinuous: true
            )

            MigrationDetailRow(
                title: String(localizable: .migrationScheduledRowPool),
                value: String(localizable: .migrationScheduledRowPoolValue),
                rowAppereance: .middle,
                isContinuous: true
            )

            MigrationDetailRow(
                title: String(localizable: .migrationScheduledRowTransfers),
                value: String(localizable: .migrationScheduledRowTransfersValue(store.sentCount, store.totalCount)),
                rowAppereance: .middle,
                isContinuous: true
            )

            MigrationDetailRow(
                title: String(localizable: .migrationScheduledRowDuration),
                value: String(localizable: .migrationPlanEtaHours(store.durationHours)),
                rowAppereance: .bottom,
                isContinuous: true
            )
        }
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        MigrationScheduledView(
            store: StoreOf<MigrationScheduled>(
                initialState: MigrationScheduled.State(
                    totalAmount: Zatoshi(1_245_800_000),
                    sentCount: 0,
                    totalCount: 5,
                    durationHours: 24
                )
            ) {
                MigrationScheduled()
            }
        )
    }
}
