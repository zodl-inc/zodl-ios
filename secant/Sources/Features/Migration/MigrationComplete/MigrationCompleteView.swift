//
//  MigrationCompleteView.swift
//  zodl
//
//  Shared terminal screen for a finished migration (Figma C6 · 2539:58787). Presentation-only — the
//  caller passes the summary numbers and a `onDone` handler. Used by both the immediate path
//  (Review → Sending → Complete) and the scheduled path (status screen, when state == .complete).
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
            hero

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Migration Complete")
                            .zFont(.semiBold, size: 28, style: Design.Text.primary)

                        Text("Your \(tokenName) is now in the Ironwood pool.")
                            .zFont(.regular, size: 16, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if hasDust {
                        dustCard
                    }

                    summaryCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }
            .screenHorizontalPadding()

            ZashiButton("Done") {
                onDone()
            }
            .screenHorizontalPadding()
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .applyScreenBackground()
    }

    // MARK: - Hero

    private var green: Color { Design.Utility.SuccessGreen._500.color(colorScheme) }

    @ViewBuilder private var hero: some View {
        ZStack {
            Circle()
                .stroke(green.opacity(0.15), lineWidth: 1)
                .frame(width: 220, height: 220)
            Circle()
                .stroke(green.opacity(0.30), lineWidth: 1)
                .frame(width: 150, height: 150)
            Circle()
                .fill(green.opacity(0.18))
                .frame(width: 96, height: 96)
            Image(systemName: "checkmark")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(green)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .background(Color(red: 0.04, green: 0.09, blue: 0.06))
        .clipped()
    }

    // MARK: - Dust card

    @ViewBuilder private var dustCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dust balance remaining")
                .zFont(.semiBold, size: 14, style: Design.Text.primary)
                .foregroundColor(.orange)

            Text("\(dust.decimalString()) \(tokenName) stayed in Orchard — below the transfer threshold. It will migrate in a future batch.")
                .zFont(.regular, size: 13, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Color.orange.opacity(0.12))
        }
    }

    // MARK: - Summary

    @ViewBuilder private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SUMMARY")
                .zFont(.medium, size: 12, style: Design.Text.tertiary)

            VStack(spacing: 0) {
                summaryRow(title: "Transferred", value: "\(transferred.decimalString()) \(tokenName)")
                if hasDust {
                    divider()
                    summaryRow(title: "Remaining dust", value: "\(dust.decimalString()) \(tokenName)")
                }
                divider()
                summaryRow(title: "Transfers", value: "\(transfersSent) of \(transfersTotal) sent")
                divider()
                summaryRow(title: "Duration", value: durationText)
            }
            .padding(.horizontal, 16)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._xl)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
            }
        }
    }

    private var durationText: String {
        durationHours <= 0 ? "Instant" : "~\(durationHours) hours"
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

    @ViewBuilder private func divider() -> some View {
        Rectangle()
            .fill(Design.Surfaces.strokeSecondary.color(colorScheme))
            .frame(height: 1)
    }
}
