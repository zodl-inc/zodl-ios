//
//  MigrationPairedIcons.swift
//  zodl
//
//  Shared header view for migration screens (MOB-1460): the account badge overlapped by a
//  circular Ironwood ("coins-swap") mark. Used by MigrationEntry and reused by later migration
//  screens. MOB-1461 parameterizes the trailing badge so MigrationNoteSplit can swap it per phase
//  (spinner while splitting, success check once confirmed) while MigrationEntry keeps the default.
//  MOB-1468 parameterizes the leading brandmark by account vendor: `.zcash` (default) keeps the
//  ZODL brandmark every existing call site already renders; `.keystone` swaps in the Keystone
//  brandmark `SignWithKeystoneView`'s account card uses — no new assets.
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
    var vendor: WalletAccount.Vendor = .zcash

    var body: some View {
        HStack(spacing: -(size * 0.18)) {
            leadingBrandmark
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

    /// Not `WalletAccount.Vendor.icon()` — that method's `.zcash` case returns a different asset
    /// (`Icons.zashiLogoSq`) than this view's existing hardcoded brandmark, which would break every
    /// current call site's pixel-identical `.zcash` default.
    private var leadingBrandmark: Image {
        switch vendor {
        case .keystone:
            return Asset.Assets.Partners.keystoneLogo.image
        case .zcash:
            return Asset.Assets.zashiLogoWithBackground.image
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

#Preview("Keystone vendor") {
    MigrationPairedIcons(vendor: .keystone)
        .padding()
}
