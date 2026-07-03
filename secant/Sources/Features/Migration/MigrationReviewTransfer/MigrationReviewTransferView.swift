//
//  MigrationReviewTransferView.swift
//  zodl
//
//  "Review Transfer" screen (MOB-1463, Figma S7 · immediate 2867:5924 / manual "3 of 5"
//  2729:8544). Visually complete per Figma; `sendResult` is declared but inert — submitting the
//  transfer lands in MOB-1466. The `confirmTapped` delegate is emitted but consumed by nobody yet.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationReviewTransferView: View {
    @Perception.Bindable var store: StoreOf<MigrationReviewTransfer>

    init(store: StoreOf<MigrationReviewTransfer>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if isIconHeaderVisible {
                            MigrationPairedIcons()
                                .padding(.bottom, 16)
                        }

                        Text(title)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.bottom, 8)

                        Text(description)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 24)

                        detailRows
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

    // MARK: - Header

    private var isIconHeaderVisible: Bool {
        store.mode == .immediate
    }

    // MARK: - Title + description

    private var title: String {
        switch store.mode {
        case .immediate:
            return String(localizable: .migrationReviewTitleImmediate)
        case .manualStep(let number, let total):
            return String(localizable: .migrationReviewTitleManual(number, total))
        }
    }

    private var description: String {
        switch store.mode {
        case .immediate:
            return String(localizable: .migrationReviewDescImmediate)
        case .manualStep:
            return String(localizable: .migrationReviewDescManual)
        }
    }

    // MARK: - Detail rows

    @ViewBuilder private var detailRows: some View {
        VStack(spacing: 0) {
            MigrationDetailRow(
                title: String(localizable: .sendAmount),
                value: "\(store.amount.decimalString()) ZEC",
                rowAppereance: .top
            )

            MigrationDetailRow(
                title: String(localizable: .sendFeeSummary),
                value: "\(store.fee.decimalString()) ZEC",
                rowAppereance: .bottom
            )
        }
    }
}

// MARK: - Previews

#Preview("Immediate") {
    NavigationView {
        MigrationReviewTransferView(
            store: StoreOf<MigrationReviewTransfer>(
                initialState: MigrationReviewTransfer.State(
                    mode: .immediate,
                    amount: Zatoshi(1_245_800_000),
                    fee: Zatoshi(100_000)
                )
            ) {
                MigrationReviewTransfer()
            }
        )
    }
}

#Preview("Manual step 3 of 5") {
    NavigationView {
        MigrationReviewTransferView(
            store: StoreOf<MigrationReviewTransfer>(
                initialState: MigrationReviewTransfer.State(
                    mode: .manualStep(number: 3, total: 5),
                    amount: Zatoshi(243_100_000),
                    fee: Zatoshi(100_000)
                )
            ) {
                MigrationReviewTransfer()
            }
        )
    }
}
