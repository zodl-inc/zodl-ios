//
//  MigrationTransferPlanView.swift
//  zodl
//
//  "Transfer Plan" screen (MOB-1463, Figma S6 · scheduled 2867:10211 / manual 2867:2198 /
//  re-created 2709:3519). Visually complete per Figma; `rows` is a placeholder and the
//  `confirmTapped` delegate is emitted but consumed by nobody yet — wiring the real proposal and
//  chaining into the rest of the migration flow lands in MOB-1466.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationTransferPlanView: View {
    @Environment(\.colorScheme) private var colorScheme
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

                        timelineRows
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

    // MARK: - Timeline rows

    @ViewBuilder private var timelineRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                timelineRow(row, isLast: index == store.rows.count - 1)
            }
        }
    }

    @ViewBuilder private func timelineRow(_ row: MigrationTransferRow, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                MigrationStepBadge(number: row.index + 1, style: badgeStyle(for: row.status))

                if !isLast {
                    Rectangle()
                        .fill(connectorColor(for: row.status).color(colorScheme))
                        .frame(width: 1.5, height: 28)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localizable: .migrationPlanTransferN(row.index + 1)))
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)

                Text(caption(for: row))
                    .zFont(size: 14, style: Design.Text.tertiary)
            }
            .padding(.top, 2)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(row.amount.decimalString()) ZEC")
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)

                if let currencyConversion = store.currencyConversion {
                    Text(currencyConversion.convert(row.amount))
                        .zFont(size: 13, style: Design.Text.tertiary)
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 16)
        }
    }

    private func badgeStyle(for status: MigrationTransferRow.Status) -> MigrationStepBadge.Style {
        switch status {
        case .sent:
            return .sent
        case .active:
            return .active
        default:
            return .pending
        }
    }

    private func connectorColor(for status: MigrationTransferRow.Status) -> Colorable {
        switch status {
        case .sent:
            return Design.Utility.SuccessGreen._500
        case .active:
            return Design.Text.primary
        default:
            return Design.Surfaces.strokeSecondary
        }
    }

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
