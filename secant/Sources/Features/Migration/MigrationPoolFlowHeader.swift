//
//  MigrationPoolFlowHeader.swift
//  zodl
//
//  ORCHARD → IRONWOOD at the top of the Migration Progress screen, above the transfer timeline
//  (Figma 5139-34627, final): one horizontally-split card — source pool on the left, destination
//  on the right, an arrow between — each side carrying its pool name, its ZEC amount, and (when
//  an exchange rate is known) its fiat value.
//
//  GROUND_RULES R9: a bubble labelled with a pool name may only show the wallet's REAL per-pool
//  balance — "if pool X has Y zec, must use Y" — the same source the home balance sheet reads.
//  Plan-derived green sums contradicted the Home sheet, so real balances render here gate-free:
//  they are passed in and the component computes nothing. Timeline checks remain an independent
//  progress signal; wallet pool accounting can advance at broadcast before a row becomes Done.
//

@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationPoolFlowHeader: View {
    /// Resolved per render and passed to every `.color(_:)` — never a hardcoded `.light`. The
    /// first pool header pinned its bubble fills to light mode while `zFont` resolved text against
    /// the real appearance, which made dark mode unreadable; the token carries both values, the
    /// caller supplies the appearance.
    @Environment(\.colorScheme) private var colorScheme

    /// What is still in Orchard — the wallet's own per-pool balance, passed in (R9).
    let orchardRemaining: Zatoshi
    /// What the wallet summary currently attributes to Ironwood.
    let ironwoodHeld: Zatoshi
    /// Fiat line under each ZEC value; nil rate hides BOTH fiat lines (never "$0.00" from a
    /// missing rate).
    let currencyConversion: CurrencyConversion?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            poolColumn(
                name: String(localizable: .migrationPoolOrchard),
                amount: orchardRemaining,
                isSource: true
            )

            Asset.Assets.Icons.arrowRight.image
                .zImage(size: 16, style: Design.Text.tertiary)

            poolColumn(
                name: String(localizable: .migrationPoolIronwood),
                amount: ironwoodHeld,
                isSource: false
            )
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    /// Both columns claim equal flexible width, which pins the arrow between them to the card's
    /// true center regardless of how long either amount renders. The source column leads, the
    /// destination trails, per the frame.
    @ViewBuilder private func poolColumn(name: String, amount: Zatoshi, isSource: Bool) -> some View {
        VStack(alignment: isSource ? .leading : .trailing, spacing: 2) {
            Text(name)
                .zFont(size: 12, style: Design.Text.tertiary)

            // Same formatter as the timeline rows below this card (`MigrationTransferTimeline`),
            // so an amount reads identically in both places.
            //
            // ONE line, always (Lukas, 2026-08-08): a full-precision mainnet amount
            // ("0.19992363 ZEC") wrapped the unit onto its own line inside the half-width
            // column. Shrink-to-fit down to half size instead of wrapping.
            Text("\(amount.decimalString()) ZEC")
                .zFont(.semiBold, size: 18, style: Design.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            if let currencyConversion {
                Text(currencyConversion.convert(amount))
                    .zFont(size: 12, style: Design.Text.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: isSource ? .leading : .trailing)
    }
}

// MARK: - Previews

#Preview("Mid-migration") {
    // Ratio picked so 12.45 ZEC reads $6,903.84 — the Figma frame's values.
    MigrationPoolFlowHeader(
        orchardRemaining: Zatoshi(1_245_000_000),
        ironwoodHeld: Zatoshi(0),
        currencyConversion: CurrencyConversion(.usd, ratio: 554.525, timestamp: 0)
    )
    .screenHorizontalPadding()
}

#Preview("No exchange rate") {
    MigrationPoolFlowHeader(
        orchardRemaining: Zatoshi(820_000_000),
        ironwoodHeld: Zatoshi(425_000_000),
        currencyConversion: nil
    )
    .screenHorizontalPadding()
}
