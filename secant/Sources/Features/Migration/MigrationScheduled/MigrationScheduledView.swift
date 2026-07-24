//
//  MigrationScheduledView.swift
//  zodl
//
//  "Migration Scheduled" screen (MOB-1463, Figma S9 · 2630:11282). The summary fields are hydrated
//  by the coordinator at push time (MOB-1458 W-E — see `MigrationScheduledStore.swift`'s header).
//  The `doneTapped` delegate is emitted and consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  MOB-1458 (W-E, Figma 3480:7631): the "Dust balance remaining" card below the summary rows,
//  shown whenever `store.hasDust` — deliberately milder, informational copy than `MigrationComplete`'s
//  own dust card (which owns the lock/migrate-anyway *decision*); the two are NOT unified.
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
                    .zFont(size: 14, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                summaryCard
                    .padding(.top, 24)

                if store.hasDust {
                    dustCard
                        .padding(.top, 16)
                }

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

    // MARK: - Dust card (MOB-1458 W-E, Figma 3480:7631)

    @ViewBuilder private var dustCard: some View {
        ZashiInfoCallout(
            style: .filled,
            title: String(localizable: .migrationScheduledDustTitle),
            body: String(localizable: .migrationScheduledDustBody),
            boldBodyPrefix: "\(store.dustAmount.decimalString()) ZEC "
        )
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
                    durationHours: 24,
                    dustAmount: Zatoshi(31_000)
                )
            ) {
                MigrationScheduled()
            }
        )
    }
}

#Preview("No dust") {
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
