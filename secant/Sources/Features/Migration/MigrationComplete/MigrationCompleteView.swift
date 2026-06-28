//
//  MigrationCompleteView.swift
//  zodl
//
//  Shared terminal screen for a finished migration (Figma "C6 · Migration Complete — Dust").
//  Presentation-only — the caller passes the summary numbers and an `onDone` handler. Used by both
//  the immediate path (Review → Sending → Complete) and the scheduled path (status screen, when
//  state == .complete).
//
//  Design: soft green top-gradient, the raised-fist celebration illustration, a summary card, and —
//  when a sub-threshold remainder is left in Orchard — a "dust balance remaining" note.
//

import SwiftUI
@preconcurrency import ZcashLightClientKit

struct MigrationCompleteView: View {
    @Environment(\.colorScheme) private var colorScheme

    let transferred: Zatoshi
    let dust: Zatoshi
    let transfersSent: Int
    let transfersTotal: Int
    let durationHours: Int
    let tokenName: String
    let onDone: () -> Void

    private var hasDust: Bool { dust.amount > 0 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    Asset.Assets.Illustrations.success1.image
                        .resizable()
                        .scaledToFit()
                        .frame(width: 140, height: 140)
                        .padding(.top, 32)

                    VStack(spacing: 8) {
                        Text(localizable: .migrationCompleteTitle)
                            .zFont(.semiBold, size: 28, style: Design.Text.primary)
                            .multilineTextAlignment(.center)

                        Text(localizable: .migrationCompleteSubtitle(tokenName))
                            .zFont(.regular, size: 16, style: Design.Text.tertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    summaryCard

                    if hasDust {
                        dustCard
                    }
                }
                .frame(maxWidth: .infinity)
                .screenHorizontalPadding()
                .padding(.bottom, 24)
            }

            ZashiButton(String(localizable: .generalDone)) {
                onDone()
            }
            .screenHorizontalPadding()
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack(alignment: .top) {
                Asset.Colors.background.color
                LinearGradient(
                    colors: [
                        Design.Utility.SuccessGreen._500.color(colorScheme).opacity(0.22),
                        Asset.Colors.background.color.opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 340)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Summary

    @ViewBuilder private var summaryCard: some View {
        VStack(spacing: 0) {
            summaryRow(title: String(localizable: .migrationCompleteTotalTransferred), value: "\(transferred.decimalString()) \(tokenName)")
            if hasDust {
                divider()
                summaryRow(title: String(localizable: .migrationCompleteRemainingDust), value: "\(dust.decimalString()) \(tokenName)")
            }
            divider()
            summaryRow(
                title: String(localizable: .migrationCompleteTransfers),
                value: String(localizable: .migrationCompleteTransfersValue(transfersSent, transfersTotal))
            )
            divider()
            summaryRow(title: String(localizable: .migrationCompleteDuration), value: durationText)
        }
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    private var durationText: String {
        durationHours <= 0
            ? String(localizable: .migrationCompleteDurationInstant)
            : String(localizable: .migrationCompleteDurationHours(durationHours))
    }

    @ViewBuilder private func summaryRow(title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .zFont(.regular, size: 14, style: Design.Text.tertiary)

            Spacer(minLength: 8)

            Text(value)
                .zFont(.semiBold, size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 14)
    }

    // MARK: - Dust note

    @ViewBuilder private var dustCard: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(localizable: .migrationCompleteDustTitle)
                    .zFont(.semiBold, size: 14, style: Design.Text.primary)

                Text(localizable: .migrationCompleteDustBody(dust.decimalString(), tokenName))
                    .zFont(.regular, size: 13, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Asset.Assets.infoOutline.image
                .zImage(size: 20, style: Design.Text.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    @ViewBuilder private func divider() -> some View {
        Rectangle()
            .fill(Design.Surfaces.strokeSecondary.color(colorScheme))
            .frame(height: 1)
    }
}
