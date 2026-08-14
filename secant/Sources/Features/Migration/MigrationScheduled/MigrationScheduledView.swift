//
//  MigrationScheduledView.swift
//  zodl
//
//  "Migration Scheduled" screen (MOB-1463, Figma S9 · 2630:11282). The summary fields are hydrated
//  by the coordinator at push time (MOB-1458 W-E — see `MigrationScheduledStore.swift`'s header).
//  The `doneTapped` delegate is emitted and consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  The "Dust balance remaining" card MOB-1458 (W-E, Figma 3480:7631) put below the summary rows is
//  GONE — the component is no longer valid here. `MigrationComplete`'s own dust card (the
//  lock/migrate-anyway *decision*, Phase 6) was never unified with this one and is unaffected.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationScheduledView: View {
    @PlatformBindable var store: StoreOf<MigrationScheduled>

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

                Text(store.isScheduling
                    ? String(localizable: .migrationSchedulingTitle)
                    : String(localizable: .migrationScheduledTitle))
                    .zFont(.semiBold, size: 28, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)

                Text(store.isScheduling
                    ? String(localizable: .migrationSchedulingSubtitle)
                    : String(localizable: .migrationScheduledSubtitle))
                    .zFont(size: 14, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                summaryCard
                    .padding(.top, 24)

                Spacer()

                // While scheduling the CTA is the progress indicator itself (the established
                // button-loading idiom) — there is nothing to acknowledge yet, and a live "Done"
                // over a half-built run would promise an exit that leads nowhere.
                if store.isScheduling {
                    ZashiButton(
                        String(localizable: .migrationSchedulingTitle),
                        accessoryView:
                            ProgressView()
                            .progressViewStyle(
                                CircularProgressViewStyle(tint: Asset.Colors.secondary.color)
                            )
                    ) { }
                    .disabled(true)
                    .padding(.bottom, 24)
                } else {
                    ZashiButton(String(localizable: .generalDone)) {
                        store.send(.doneTapped)
                    }
                    .padding(.bottom, 24)
                }
            }
            .padding(.vertical, 1)
            .screenHorizontalPadding()
            .navigationBarBackButtonHidden()
        }
        .applySuccessScreenBackground()
    }

    // MARK: - Summary card

    /// The SAME four labels in both phases — only the values are unknown while scheduling, which is
    /// exactly what the design draws. Placeholder widths differ per row so the card reads as data
    /// arriving rather than as four identical bars; they approximate the real values' lengths, so
    /// nothing jumps sideways when the numbers land.
    @ViewBuilder private var summaryCard: some View {
        let summary = store.summary

        VStack(spacing: 0) {
            MigrationDetailRow(
                title: String(localizable: .migrationScheduledRowTotal),
                value: summary.map { "\($0.totalAmount.decimalString()) ZEC" } ?? "",
                rowAppereance: .top,
                isContinuous: true,
                skeletonWidth: summary == nil ? 68 : nil
            )

            MigrationDetailRow(
                title: String(localizable: .migrationScheduledRowPool),
                value: String(localizable: .migrationScheduledRowPoolValue),
                rowAppereance: .middle,
                isContinuous: true,
                skeletonWidth: summary == nil ? 140 : nil
            )

            MigrationDetailRow(
                title: String(localizable: .migrationScheduledRowTransfers),
                value: summary.map { String(localizable: .migrationScheduledRowTransfersValue($0.sentCount, $0.totalCount)) } ?? "",
                rowAppereance: .middle,
                isContinuous: true,
                skeletonWidth: summary == nil ? 52 : nil
            )

            MigrationDetailRow(
                title: String(localizable: .migrationScheduledRowDuration),
                value: summary.map { String(localizable: .migrationPlanEtaHours($0.durationHours)) } ?? "",
                rowAppereance: .bottom,
                isContinuous: true,
                skeletonWidth: summary == nil ? 76 : nil
            )
        }
    }
}

// MARK: - Previews

/// The screen the user actually lands on first: committed, first drive in flight.
#Preview("Scheduling") {
    NavigationView {
        MigrationScheduledView(
            store: StoreOf<MigrationScheduled>(
                initialState: MigrationScheduled.State(phase: .scheduling)
            ) {
                MigrationScheduled()
            }
        )
    }
}

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
