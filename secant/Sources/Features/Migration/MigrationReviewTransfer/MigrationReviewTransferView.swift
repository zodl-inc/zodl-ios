//
//  MigrationReviewTransferView.swift
//  zodl
//
//  "Review Transfer" screen (MOB-1463, Figma S7 · immediate 2867:5924 / manual "3 of 5"
//  2729:8544). `onAppear` loads Amount/Fee live (immediate mode) via the store; when the manual-step
//  variant is a flow re-entry root (`isFlowRoot`), its back control closes the flow instead of
//  popping (MOB-1466). The `confirmTapped` delegate is emitted but consumed by nobody yet —
//  chaining is the coordinator's job (phase 3).
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationReviewTransferView: View {
    @Perception.Bindable var store: StoreOf<MigrationReviewTransfer>
    @Shared(.inMemory(.exchangeRate)) private var currencyConversion: CurrencyConversion?

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

                        if isThisTransferVisible {
                            thisTransferBlock
                                .padding(.bottom, 16)
                        }

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
            .applyPresentationModifier(store: store)
        }
        .applyScreenBackground()
        .onAppear {
            store.send(.onAppear)
        }
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

    // MARK: - This Transfer

    /// The "This Transfer" summary block is manual-mode only — immediate mode is untouched.
    private var isThisTransferVisible: Bool {
        store.mode != .immediate
    }

    private var stepNumber: Int {
        guard case .manualStep(let number, _) = store.mode else { return 0 }
        return number
    }

    private var stepTotal: Int {
        guard case .manualStep(_, let total) = store.mode else { return 0 }
        return total
    }

    @ViewBuilder private var thisTransferBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .migrationReviewThisTransferTitle)
                    .zFont(.medium, size: 14, style: Design.Text.primary)

                Text(localizable: .migrationReviewCannotBeUndone)
                    .zFont(size: 12, style: Design.Text.tertiary)
            }

            thisTransferRow
        }
    }

    @ViewBuilder private var thisTransferRow: some View {
        HStack(alignment: .top, spacing: 12) {
            MigrationStepBadge(number: stepNumber, style: .active, size: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .migrationReviewTransferOfTotal(stepNumber, stepTotal))
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)

                Text(localizable: .migrationReviewSendsNow)
                    .zFont(size: 14, style: Design.Text.tertiary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(store.amount.decimalString()) ZEC")
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)

                if let currencyConversion {
                    Text(currencyConversion.convert(store.amount))
                        .zFont(size: 13, style: Design.Text.tertiary)
                }
            }
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

// MARK: - Presentation modifier

private extension View {
    /// Only the manual-step variant can be a re-entry root — immediate mode is always reached via
    /// normal push, so a plain pop stands there regardless of `isFlowRoot`.
    @ViewBuilder func applyPresentationModifier(store: StoreOf<MigrationReviewTransfer>) -> some View {
        if store.mode != .immediate && store.isFlowRoot {
            zashiBackV2 {
                store.send(.closeTapped)
            }
        } else {
            zashiBack()
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
