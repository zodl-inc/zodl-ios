//
//  MigrationTransferPlanView.swift
//  zodl
//
//  "Transfer Plan" screen (MOB-1463, Figma S6 · scheduled 2867:10211 / manual 2867:2198 /
//  re-created 2709:3519). `onAppear` loads a fresh proposal (or leaves an injected schedule alone)
//  via the store; the `confirmTapped` delegate is emitted but consumed by nobody yet — chaining
//  into the rest of the migration flow is the coordinator's job (MOB-1466 phase 3).
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationTransferPlanView: View {
    @Perception.Bindable var store: StoreOf<MigrationTransferPlan>

    init(store: StoreOf<MigrationTransferPlan>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.bottom, 8)

                        Text(description)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 24)

                        MigrationTransferTimeline(rows: store.rows, caption: caption(for:))
                    }
                    .padding(.vertical, 1)
                }

                ZashiButton(String(localizable: .generalConfirm)) {
                    store.send(.confirmTapped)
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .screenHorizontalPadding()
            .zashiBack()
        }
        .applyScreenBackground()
        .onAppear {
            store.send(.onAppear)
        }
    }

    // MARK: - Title + description

    private var title: String {
        switch store.variant {
        case .scheduled, .recreated:
            return String(localizable: .migrationPlanTitleConfirm)
        case .manual:
            return String(localizable: .migrationPlanTitleManual)
        }
    }

    private var description: String {
        let transferCount = store.rows.count

        switch store.variant {
        case .scheduled:
            return String(localizable: .migrationPlanDescScheduled(transferCount, store.totalDurationHours))
        case .manual:
            return String(localizable: .migrationPlanDescManual(transferCount, store.totalDurationHours))
        case .recreated:
            return String(localizable: .migrationPlanDescRecreated(transferCount, store.totalDurationHours))
        }
    }

    // MARK: - Caption

    private func caption(for row: MigrationTransferRow) -> String {
        switch row.status {
        case .sent:
            return String(localizable: .migrationPlanSentAgo(row.hoursFromNow))
        case .active:
            return store.variant == .recreated
                ? String(localizable: .migrationPlanReadyNow)
                : eta(hoursFromNow: row.hoursFromNow)
        default:
            return eta(hoursFromNow: row.hoursFromNow)
        }
    }

    private func eta(hoursFromNow: Int) -> String {
        hoursFromNow == 0
            ? String(localizable: .migrationPlanEtaFirst)
            : String(localizable: .migrationPlanEtaHours(hoursFromNow))
    }
}

// MARK: - Mock data

private extension IdentifiedArray where ID == MigrationTransferRow.ID, Element == MigrationTransferRow {
    /// The 5-transfer set from the Figma frames (3.51220 / 2.87410 / 2.43100 / 1.99830 / 1.64240 ZEC).
    static var previewRows: Self {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(351_220_000), status: .active, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(287_410_000), status: .pending, hoursFromNow: 6),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(243_100_000), status: .pending, hoursFromNow: 12),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(199_830_000), status: .pending, hoursFromNow: 18),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(164_240_000), status: .pending, hoursFromNow: 24)
        ]
    }

    /// The re-created variant's frame: two already sent, one active, two pending.
    static var previewRecreatedRows: Self {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(351_220_000), status: .sent, hoursFromNow: 17),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(287_410_000), status: .sent, hoursFromNow: 6),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(243_100_000), status: .active, hoursFromNow: 0),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(199_830_000), status: .pending, hoursFromNow: 6),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(164_240_000), status: .pending, hoursFromNow: 12)
        ]
    }
}

// MARK: - Previews

#Preview("Scheduled") {
    NavigationView {
        MigrationTransferPlanView(
            store: StoreOf<MigrationTransferPlan>(
                initialState: MigrationTransferPlan.State(
                    variant: .scheduled,
                    rows: .previewRows,
                    totalDurationHours: 24
                )
            ) {
                MigrationTransferPlan()
            }
        )
    }
}

#Preview("Manual") {
    NavigationView {
        MigrationTransferPlanView(
            store: StoreOf<MigrationTransferPlan>(
                initialState: MigrationTransferPlan.State(
                    variant: .manual,
                    rows: .previewRows,
                    totalDurationHours: 24
                )
            ) {
                MigrationTransferPlan()
            }
        )
    }
}

#Preview("Recreated") {
    NavigationView {
        MigrationTransferPlanView(
            store: StoreOf<MigrationTransferPlan>(
                initialState: MigrationTransferPlan.State(
                    variant: .recreated,
                    rows: .previewRecreatedRows,
                    totalDurationHours: 12
                )
            ) {
                MigrationTransferPlan()
            }
        )
    }
}
