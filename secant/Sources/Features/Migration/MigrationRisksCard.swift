//
//  MigrationRisksCard.swift
//  zodl
//
//  Small "What are the risks?" info card (MOB-1497 T3, Figma 4207:10692 / dark 4207:10875): shown by
//  the redesigned custom-server Tor sheet variant (`MigrationTorSheetView`) between the body copy and
//  the "Continue without Tor" / "Switch Server" buttons, spelling out the R11 IP-exposure risk before
//  the user picks either option. Mirrors `MigrationTorSheetView`'s toggle-card background idiom
//  (`Surfaces.bgPrimary` fill + a stroked border), swapped to `strokeTertiary` per the canvas.
//

import SwiftUI

struct MigrationRisksCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let bodyText: String

    init(body: String) {
        self.bodyText = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localizable: .migrationTorSheetRisksTitle)
                .zFont(.semiBold, size: 16, style: Design.Text.primary)

            Text(bodyText)
                .zFont(size: 12, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius._2xl)
                        .strokeBorder(Design.Surfaces.strokeTertiary.color(colorScheme))
                }
        }
        // Figma Shadow/XXS (node 4588:28496) — same two-layer treatment already used by other
        // `bgPrimary`-fill/stroked cards (AvailableBalanceView, FloatingArrow, HomeView).
        .shadow(color: .black.opacity(0.02), radius: 0.66667, x: 0, y: 1.33333)
        .shadow(color: .black.opacity(0.08), radius: 1.33333, x: 0, y: 1.33333)
    }
}

// MARK: - Previews

#Preview {
    VStack(spacing: 16) {
        MigrationRisksCard(
            body: "Without Tor, your IP address is exposed to the custom server and could be linked to your full balance."
        )

        MigrationRisksCard(
            body: "Without Tor, your IP address is exposed to the custom server and could be linked to the migration amounts."
        )
    }
    .screenHorizontalPadding()
}
