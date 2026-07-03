//
//  MigrationPairedIcons.swift
//  zodl
//
//  Shared header view for migration screens (MOB-1460): the ZODL account badge overlapped by a
//  circular Ironwood ("coins-swap") mark. Used by MigrationEntry and reused by later migration
//  screens. MOB-1461 parameterizes the trailing badge so MigrationNoteSplit can swap it per phase
//  (spinner while splitting, success check once confirmed) while MigrationEntry keeps the default.
//

import SwiftUI

struct MigrationPairedIcons: View {
    enum Badge: Equatable {
        /// Default — current appearance (bgTertiary circle + coinsSwap glyph).
        case coinsSwap
        /// bgTertiary circle + `ProgressView()`.
        case spinner
        /// Light-green circle + `Icons.checkVerifiedFilled` in `SuccessGreen._500`.
        case successCheck
    }

    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 48
    var badge: Badge = .coinsSwap

    var body: some View {
        HStack(spacing: -(size * 0.18)) {
            Asset.Assets.zashiLogoWithBackground.image
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(Circle())

            ZStack {
                Circle()
                    .fill(badgeCircleColor.color(colorScheme))

                switch badge {
                case .coinsSwap:
                    Asset.Assets.Icons.coinsSwap.image
                        .zImage(size: size * 0.5, style: Design.Text.primary)
                case .spinner:
                    ProgressView()
                case .successCheck:
                    Asset.Assets.Icons.checkVerifiedFilled.image
                        .zImage(size: size * 0.5, style: Design.Utility.SuccessGreen._500)
                }
            }
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .stroke(Design.Surfaces.bgPrimary.color(colorScheme), lineWidth: 2)
            }
        }
    }

    private var badgeCircleColor: Colorable {
        switch badge {
        case .coinsSwap, .spinner:
            return Design.Surfaces.bgTertiary
        case .successCheck:
            return Design.Utility.SuccessGreen._100
        }
    }
}

// MARK: - Previews

#Preview("Coins swap") {
    MigrationPairedIcons()
        .padding()
}

#Preview("Spinner") {
    MigrationPairedIcons(badge: .spinner)
        .padding()
}

#Preview("Success check") {
    MigrationPairedIcons(badge: .successCheck)
        .padding()
}
