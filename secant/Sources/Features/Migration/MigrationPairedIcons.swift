//
//  MigrationPairedIcons.swift
//  zodl
//
//  Shared header view for migration screens (MOB-1460): the ZODL account badge overlapped by a
//  circular Ironwood ("coins-swap") mark. Used by MigrationEntry now and reused by later migration
//  screens.
//

import SwiftUI

struct MigrationPairedIcons: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 48

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

// MARK: - Previews

#Preview {
    MigrationPairedIcons()
        .padding()
}
