//
//  MigrationPairedIcons.swift
//  zodl
//
//  The ZODL + Ironwood paired header icons shown across migration screens (Figma "All Icons"): the
//  app brandmark overlapped by the Ironwood ("coins-swap") mark.
//

import SwiftUI

struct MigrationPairedIcons: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 44

    var body: some View {
        HStack(spacing: -(size * 0.18)) {
            Asset.Assets.zashiLogoWithBackground.image
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(Circle())

            ZStack {
                Circle()
                    .fill(Design.Surfaces.bgTertiary.color(colorScheme))

                Asset.Assets.Icons.coinsSwap.image
                    .zImage(size: size * 0.5, style: Design.Text.primary)
            }
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .stroke(Design.Surfaces.bgPrimary.color(colorScheme), lineWidth: 2)
            }
        }
    }
}
