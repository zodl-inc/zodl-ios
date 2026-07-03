//
//  MigrationCompleteView.swift
//  zodl
//
//  "Migration Complete" screen (MOB-1464, Figma S12 · 2696:7267). Visually complete per Figma; all
//  summary fields are placeholders — wiring the real data lands in MOB-1466. The `gotItTapped`
//  delegate is emitted but consumed by nobody yet.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationCompleteView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<MigrationComplete>

    init(store: StoreOf<MigrationComplete>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Spacer()

                Asset.Assets.Illustrations.success1.image
                    .resizable()
                    .frame(width: 148, height: 148)

                Text(localizable: .migrationCompleteTitle)
                    .zFont(.semiBold, size: 28, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)

                Text(localizable: .migrationCompleteSubtitle)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                summaryCard
                    .padding(.top, 24)

                if store.hasDust {
                    dustCallout
                        .padding(.top, 16)
                }

                Spacer()

                ZashiButton(String(localizable: .migrationGotIt)) {
                    store.send(.gotItTapped)
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
                title: String(localizable: .migrationCompleteRowTotal),
                value: "\(store.totalTransferred.decimalString()) ZEC",
                rowAppereance: .top
            )

            if store.hasDust {
                MigrationDetailRow(
                    title: String(localizable: .migrationCompleteRowDust),
                    value: "\(store.dust.decimalString()) ZEC",
                    rowAppereance: .middle
                )
            }

            MigrationDetailRow(
                title: String(localizable: .migrationCompleteRowTransfers),
                value: String(localizable: .migrationCompleteRowTransfersValue(store.transfersSent, store.transfersTotal)),
                rowAppereance: .middle
            )

            MigrationDetailRow(
                title: String(localizable: .migrationCompleteRowDuration),
                value: String(localizable: .migrationPlanEtaHours(store.durationHours)),
                rowAppereance: .bottom
            )
        }
    }

    // MARK: - Dust callout

    @ViewBuilder private var dustCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text(localizable: .migrationCompleteDustTitle)
                    .zFont(.semiBold, size: 14, style: Design.Text.primary)

                Spacer()

                Asset.Assets.infoOutline.image
                    .zImage(size: 20, style: Design.Text.tertiary)
            }

            dustBody
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    @ViewBuilder private var dustBody: some View {
        let amountText = "\(store.dust.decimalString()) ZEC"
        let markdown = String(localizable: .migrationCompleteDustBody("^[\(amountText)](style: 'boldPrimary')"))

        if let attrText = try? AttributedString(markdown: markdown, including: \.zashiApp) {
            ZashiText(withAttributedString: attrText, colorScheme: colorScheme)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Previews

#Preview("With dust") {
    NavigationView {
        MigrationCompleteView(
            store: StoreOf<MigrationComplete>(
                initialState: MigrationComplete.State(
                    totalTransferred: Zatoshi(1_245_800_000),
                    dust: Zatoshi(31_000),
                    transfersSent: 5,
                    transfersTotal: 5,
                    durationHours: 24
                )
            ) {
                MigrationComplete()
            }
        )
    }
}

#Preview("Clean, no dust") {
    NavigationView {
        MigrationCompleteView(
            store: StoreOf<MigrationComplete>(
                initialState: MigrationComplete.State(
                    totalTransferred: Zatoshi(1_245_800_000),
                    dust: .zero,
                    transfersSent: 5,
                    transfersTotal: 5,
                    durationHours: 24
                )
            ) {
                MigrationComplete()
            }
        )
    }
}
