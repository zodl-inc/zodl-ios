//
//  MigrationPairedIcons.swift
//  zodl
//
//  Shared header view for migration screens (MOB-1460): the account badge overlapped by a
//  circular Ironwood ("coins-swap") mark. MOB-1461 added the trailing-badge parameter (a `spinner`
//  while a phase runs, a `successCheck` once confirmed) for the per-phase splitting screen; MOB-1513
//  (R2) removed that screen (the split phase folded into Migration Progress), so the live consumers —
//  MigrationEntry and MigrationReviewTransfer — both render the default `.coinsSwap` badge, and the
//  spinner/success variants now survive only in this file's previews. MOB-1468 parameterizes the
//  leading brandmark by account vendor: `.zcash` (default) keeps the Zodl brandmark every existing
//  call site already renders; `.keystone` swaps in the Keystone brandmark `SignWithKeystoneView`'s
//  account card uses — no new assets.
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
            return Asset.Assets.Partners.keystone.image
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
